-- SyncFriends: keeps the friend lists of your own nodes in sync over
-- (distant) mail. Every message carries the sender's complete friend list
-- ("state", not tickets), so late or duplicate mails do no harm.
--
-- Trigger: the event "A mail arrives" (Automation tab): applies received lists.
-- Also needs regular runs, e.g. a timer every 1-3 hours: sends the list when it
-- changed, and at least once a day.
-- Needs sandbox-write: reads mail and invites (sensitive), adds friends (write).
--
-- How partners keep in touch:
-- - Every list acknowledges the newest list we got from its recipient. A
--   partner whose acknowledgement shows that it missed one of our lists gets
--   the current one right away. Replies are never answered, so crossing mails
--   cannot start a ping-pong.
-- - The daily resend doubles as a heartbeat. A partner that left SILENT_SENDS of
--   our lists unanswered and that we have not heard from for SILENT_AFTER
--   counts as offline and only gets a list every PROBE_SECONDS, so its mailbox
--   does not fill up. Only lists we actually sent count: time we were offline
--   ourselves does not make a partner silent.
-- - A partner that writes to us, but whose mails keep showing that our lists do
--   not reach it, most likely rejects our mail (its distant-mail permission).
--   It is throttled like an offline one, and the log says so.
-- - After a break (RetroShare started, or no run for AWAKE_GAP) every partner
--   gets our list once, offline ones included, so both sides catch up quickly.
--
-- Every run logs a banner with the mode, one line per partner (contacted or
-- skipped, with the reason), and a short summary. If nothing seems to happen,
-- read that log first: DRY_RUN, a silent partner, a partner that does not get
-- our mail, and a failed send each say so there.
--
-- Configuration. It is part of the approved code: changing it needs a new approval.
local SEND_AS        = "<own identity id>"         -- own identity the mails come from
local SEND_TO        = { "<partner identity id>" } -- identities that get my friend list
local ACCEPT_FROM    = { "<partner identity id>" } -- identities that may change my friends
local REMOVE_FRIENDS = false           -- also remove friends the partner removed
local RESEND_SECONDS = 24 * 3600       -- send the list at least this often
local SILENT_AFTER   = 3 * RESEND_SECONDS -- no mail from a partner this long ...
local SILENT_SENDS   = 3               -- ... and this many of our lists unanswered: treat as offline
local PROBE_SECONDS  = 7 * 24 * 3600   -- offline partners get the list only this often
local AWAKE_GAP      = 12 * 3600       -- no run this long: we were offline (keep it above the timer interval)
local DRY_RUN        = true            -- only log friend add/remove (mails are still sent)

local SUBJECT  = "[Lua4RS SyncFriends]"
local PROTOCOL = 1
local DELIVERY_GRACE = 3600 -- a list younger than this may still be on its way
local KEEP_SENT      = 10   -- remembered lists per partner (for acknowledgements)
local DEAF_MAILS     = 2    -- this many mails in a row that should acknowledge a list but do not

local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

-- Human-readable duration, integer only (no locale-dependent decimals).
local function duration(s)
    s = math.max(0, math.floor(s))
    if s < 90 then return s .. "s" end
    if s < 90 * 60 then return math.floor(s / 60) .. "m" end
    if s < 48 * 3600 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 86400) .. "d"
end

-- Every change to friends goes through here: with DRY_RUN (and in test runs)
-- it is only logged.
local dryRun = DRY_RUN
local selftest = false -- run with simulated args (read-only): never sends
local function act(what, f, ...)
    if dryRun then print("would " .. what) return true end
    local ok = f(...)
    print((ok and "" or "FAILED: ") .. what)
    return ok
end

-- Own friend list: friends[pgpId] = { pgpId, name, locations = { {sslId, name, invite} } }
local function ownFriends()
    local byPgp, order = {}, {}
    for _, ssl in ipairs(peers.getFriendList() or {}) do
        local d = peers.getPeerDetails(ssl)
        if d and d.gpg_id then
            local f = byPgp[d.gpg_id]
            if not f then
                f = { pgpId = d.gpg_id, name = d.name or "", locations = jsonapi.array() }
                byPgp[d.gpg_id] = f
                order[#order + 1] = d.gpg_id
            end
            local invite = peers.getShortInvite(ssl)
            if invite then
                f.locations[#f.locations + 1] = { sslId = ssl, name = d.location or "", invite = invite }
            end
        end
    end
    table.sort(order)
    local list = jsonapi.array()
    for _, pgp in ipairs(order) do list[#list + 1] = byPgp[pgp] end
    return list
end

-- Order-independent summary of a list, to notice changes.
local function fingerprint(friends)
    local keys = {}
    for _, f in ipairs(friends) do
        for _, l in ipairs(f.locations) do keys[#keys + 1] = f.pgpId .. "/" .. l.sslId end
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- Store layout:
--   seq          number of our last mail (one counter for all partners)
--   lastRun      time of our last run (to notice breaks)
--   wokeAt       when we last came back from a break
--   contact:<id> what we sent to the partner: since (first considered), time
--                and seq of our last list, fingerprint, unanswered (lists since
--                we last heard from it), sent (our last KEEP_SENT lists:
--                {seq, time}), acked (newest of our lists it acknowledged;
--                nil: its version sends no acknowledgements), stale (its mails
--                in a row that left an overdue list unacknowledged)
--   partner:<id> what we got from the partner: seq, pgpIds, time (we got it),
--                sent (it wrote it, its clock)
local function send(recipients, message, reply)
    message.syncfriends = PROTOCOL
    message.sent = os.time()
    message.reply = reply or nil
    -- Acknowledgements: per recipient the newest of its lists we got.
    message.acks = {}
    for _, id in ipairs(recipients) do
        message.acks[id] = (store.get("partner:" .. id) or {}).seq or 0
    end
    local seq = (store.get("seq") or 0) + 1
    message.seq = seq
    local body = jsonapi.encode(message)
    local sent, err = mail.sendMail(SEND_AS, recipients, SUBJECT, body)
    if sent >= #recipients and not err then
        print(("sent %s%s #%d (%d bytes) to %d partner(s)")
            :format(message.type, reply and " (reply)" or "", seq, #body, sent))
    else
        -- Only local problems end up here: SEND_AS is not an own identity, or a
        -- recipient identity is unknown on this node. A partner that rejects our
        -- mail (its distant-mail permission) is not reported here; it shows in
        -- its acknowledgements.
        print(("FAILED to send %s #%d (%d bytes): reached %d of %d partner(s)%s")
            :format(message.type, seq, #body, sent, #recipients, err and (": " .. err) or ""))
    end
    if sent > 0 then store.set("seq", seq) end
    return sent > 0, seq
end

-- When did we last get a valid message from `id`? Partners we never heard from
-- count from the first time we considered sending to them, so a partner that
-- never answers also goes silent.
local function lastHeard(id, contact)
    local partner = store.get("partner:" .. id) or {}
    return partner.time or contact.since
end

-- How many of our lists has `id` not answered? Counts sends, not time, so our
-- own downtime does not count against the partner. Mail from the partner after
-- our last send resets it.
local function unanswered(id, contact)
    local heard = (store.get("partner:" .. id) or {}).time
    if heard and heard >= (contact.time or 0) then return 0 end
    return contact.unanswered or 0
end

-- How many of our lists sent before `t` has the partner not acknowledged?
local function unackedBefore(contact, t)
    local n = 0
    for _, s in ipairs(contact.sent or {}) do
        if s.seq > (contact.acked or 0) and s.time < t then n = n + 1 end
    end
    return n
end

-- Not heard from `id` for SILENT_AFTER (wall-clock time). For partners that
-- send no acknowledgements: decides whether an incoming list gets an answer.
local function quietLong(id)
    local heard = lastHeard(id, store.get("contact:" .. id) or {})
    return heard ~= nil and os.time() - heard > SILENT_AFTER
end

-- Sends the own list to the partners in SEND_TO (or only to `only`) for which
-- it is due. Per partner: active ones get it on every change and at least every
-- RESEND_SECONDS, silent ones and ones that do not get our mail only every
-- PROBE_SECONDS, all once after a break. `reply` sends anyway, marked as reply.
-- Logs one line per partner (contacted / skipped, with the reason).
local function sendList(reply, only)
    local friends = ownFriends()
    local fp = fingerprint(friends)
    local now = os.time()
    local wokeAt = store.get("wokeAt")
    local recipients, contacts, skipped = {}, {}, 0
    for _, id in ipairs(SEND_TO) do
        if not only or id == only then
            local c = store.get("contact:" .. id) or {}
            if not c.since then c.since = now; store.set("contact:" .. id, c) end
            local heard = (store.get("partner:" .. id) or {}).time
            local open = unanswered(id, c)
            local silent = open >= SILENT_SENDS and now - lastHeard(id, c) > SILENT_AFTER
            local deaf = not silent and (c.stale or 0) >= DEAF_MAILS
            local age = now - (c.time or 0)
            local woke = wokeAt and (c.time or 0) < wokeAt and age >= AWAKE_GAP
            local function probe(state)
                local due = age >= PROBE_SECONDS
                return due, state .. (due and ", probe due" or (", last sent " .. duration(age) ..
                    " ago, next probe in " .. duration(PROBE_SECONDS - age)))
            end
            local due, reason
            if reply then
                due, reason = true, "reply"
            elseif not c.time then
                due, reason = true, "first contact"
            elseif woke then
                due, reason = true, "we are back from a break, catching up"
            elseif silent then
                local state = (heard and ("silent for " .. duration(now - heard))
                    or ("never heard from it in " .. duration(now - c.since)))
                    .. (", %d list(s) unanswered"):format(open)
                due, reason = probe(state)
                if (c.stale or 0) > 0 then
                    reason = reason .. "; its last mail showed that our lists do not reach it:"
                        .. " check its distant-mail permission"
                elseif heard then
                    reason = reason .. "; offline, or mail between us does not get through"
                else
                    reason = reason .. "; offline, or mail between us does not get through:"
                        .. " check the distant-mail permission on both nodes"
                end
            elseif deaf then
                due, reason = probe(("writes to us, but its last %d mails show that our lists do not reach it")
                    :format(c.stale))
                reason = reason .. "; it rejects our mail: check its distant-mail permission"
            elseif c.fingerprint ~= fp then
                due, reason = true, "friend list changed"
            elseif age >= RESEND_SECONDS then
                due, reason = true, "periodic resend due"
            else
                due, reason = false, ("no change, sent " .. duration(age) ..
                    " ago, next resend in " .. duration(RESEND_SECONDS - age))
            end
            if due then
                recipients[#recipients + 1] = id
                contacts[id] = c
                print(("  -> %s: SEND (%s)"):format(id, reason))
            else
                skipped = skipped + 1
                print(("  -- %s: skip (%s)"):format(id, reason))
            end
        end
    end
    if #recipients == 0 then
        if only then
            print(("reply: %s is not in SEND_TO, not sending"):format(only))
        else
            print(("summary: nothing to send (%d partner(s) up to date or offline)"):format(skipped))
        end
        return
    end
    local ok, seq = send(recipients, { type = "list", friends = friends }, reply)
    if ok then
        for id, c in pairs(contacts) do
            c.unanswered = unanswered(id, c) + 1 -- before c.time moves on
            c.fingerprint, c.time, c.seq = fp, now, seq
            local sent = c.sent or {}
            sent[#sent + 1] = { seq = seq, time = now }
            while #sent > KEEP_SENT do table.remove(sent, 1) end
            c.sent = sent
            store.set("contact:" .. id, c)
        end
    end
    print(("summary: %s %d partner(s), skipped %d%s")
        :format(ok and "contacted" or "tried", #recipients, skipped, ok and "" or " -- SEND FAILED, see above"))
end

-- Applies a partner's list. Prints every action and a count summary.
local function applyList(from, message)
    local mine = {}
    for _, ssl in ipairs(peers.getFriendList() or {}) do mine[ssl] = true end
    local ownPgp, ownSsl = peers.getGPGOwnId(), peers.getOwnId()

    local added, known, failed = 0, 0, 0
    local now = {}
    for _, f in ipairs(message.friends or {}) do
        now[f.pgpId] = true
        if f.pgpId ~= ownPgp then
            for _, l in ipairs(f.locations or {}) do
                if l.sslId == ownSsl then
                    -- our own location: nothing to do
                elseif mine[l.sslId] then
                    known = known + 1
                elseif act(("add %s (%s / %s)"):format(l.sslId, f.name, l.name), peers.acceptInvite, l.invite) then
                    added = added + 1
                else
                    failed = failed + 1
                end
            end
        end
    end

    local removed = 0
    local key = "partner:" .. from
    local previous = store.get(key) or {}
    if REMOVE_FRIENDS then
        for _, pgp in ipairs(previous.pgpIds or {}) do
            if not now[pgp] and pgp ~= ownPgp and peers.isGPGAccepted(pgp) then
                if act(("remove %s (%s)"):format(pgp, peers.getGPGName(pgp) or "?"), peers.removeFriend, pgp) then
                    removed = removed + 1
                else
                    failed = failed + 1
                end
            end
        end
    end
    local pgpIds = {}
    for pgp in pairs(now) do pgpIds[#pgpIds + 1] = pgp end
    table.sort(pgpIds)
    store.set(key, { seq = message.seq, pgpIds = pgpIds }) -- time, sent: set by handle()
    print(("applied list from %s: %d location(s) added, %d already known, %d removed, %d FAILED%s%s")
        :format(from, added, known, removed, failed,
            REMOVE_FRIENDS and "" or " (REMOVE_FRIENDS off)",
            dryRun and " -- DRY_RUN: only logged, nothing changed" or ""))
end

local function answer(to, why)
    if selftest then
        print("would reply with own list (" .. why .. ")")
    else
        print("replying with own list (" .. why .. ")")
        sendList(true, to)
    end
end

-- Checks and applies one message (decoded JSON) from `from`.
-- RetroShare authenticates the sender before a mail arrives (distant mail: the
-- author's signature is checked by GxsTrans/GRouter), so `from` can be trusted;
-- it must be an identity (not a node) listed in ACCEPT_FROM.
local function handle(from, fromIdentity, message)
    if not fromIdentity then print("ignored: sender " .. from .. " is not an identity") return end
    if not contains(ACCEPT_FROM, from) then print("ignored: sender " .. from .. " is not in ACCEPT_FROM") return end
    if type(message) ~= "table" or message.syncfriends ~= PROTOCOL then print("ignored: unknown format") return end
    local previous = store.get("partner:" .. from) or {}
    local acks = type(message.acks) == "table" and message.acks[SEND_AS]
    local ack = type(acks) == "number" and math.floor(acks) or nil -- nil: older version
    print(("from %s: %s%s #%s, acknowledges our #%s"):format(from, tostring(message.type),
        message.reply and " (reply)" or "", tostring(message.seq), ack or "? (no acknowledgements)"))

    -- The partner already has a newer list from us than our counter says: we
    -- lost our store (reinstalled?), so it ignores our lists as old ones.
    local jumped = false
    local ourSeq = store.get("seq") or 0
    if ack and ack > ourSeq then
        print(("our counter #%d is behind what the partner has (#%d), store lost? Continuing after it")
            :format(ourSeq, ack))
        store.set("seq", ack)
        jumped = true
    end

    if (message.seq or 0) <= (previous.seq or 0) then
        print(("ignored: #%s from %s is not newer than #%s"):format(message.seq, from, previous.seq or 0))
        -- Older, and it acknowledges none of our lists: the partner lost its
        -- store and counts from 1 again. Our answer tells it where to continue.
        if ack == 0 and not message.reply and (message.seq or 0) < previous.seq then
            answer(from, "partner counts from 1 again, store lost?")
        end
        return
    end

    local missed = 0
    local c = contains(SEND_TO, from) and (store.get("contact:" .. from) or {}) or nil
    if ack and c then
        c.acked = math.max(c.acked or 0, ack)
        -- It was online when it wrote its previous mail (its clock): what we
        -- had sent well before should have reached it before it wrote this one,
        -- at least DELIVERY_GRACE later. Lists sent while it was offline arrive
        -- later, so an acknowledgement that only lags behind those proves nothing.
        local before, now = tonumber(previous.sent), tonumber(message.sent)
        if before and now and now >= before + DELIVERY_GRACE then
            local overdue = unackedBefore(c, before - DELIVERY_GRACE)
            c.stale = overdue > 0 and (c.stale or 0) + 1 or 0
        end
        store.set("contact:" .. from, c)
        -- Only our newest list matters (each one is complete). It is missing
        -- if not acknowledged, unless we sent it so recently that it may still
        -- be on its way (e.g. our reply to an earlier mail of the same batch).
        if c.seq and c.acked < c.seq and os.time() - (c.time or 0) >= DELIVERY_GRACE then
            missed = unackedBefore(c, os.time())
        end
    end
    local quiet = quietLong(from) -- before this message counts as heard

    if message.type == "request" then
        store.set("partner:" .. from, { seq = message.seq, pgpIds = previous.pgpIds })
    elseif message.type == "list" then
        applyList(from, message)
    else
        print("ignored: unknown type " .. tostring(message.type))
        return
    end
    local p = store.get("partner:" .. from)
    p.time, p.sent = os.time(), message.sent
    store.set("partner:" .. from, p)

    -- Answer right away when the partner lacks our current list. Never answer
    -- a reply (that would let crossing mails ping-pong), except when our
    -- counter was behind: then it ignored our last lists, and this happens once.
    local why
    if jumped then
        why = "partner ignored our last list(s)"
    elseif message.reply then
        why = nil
    elseif message.type == "request" then
        why = "partner asked for it"
    elseif not previous.seq then
        why = "first contact"
    elseif missed > 0 then
        why = ("partner did not get %d of our list(s)"):format(missed)
    elseif ack == nil and quiet then
        why = "partner was silent"
    end
    if why then answer(from, why) end
end

local function onMail(msgId)
    local m = mail.getMessage(msgId)
    if not m or m.title ~= SUBJECT then return end -- not ours: leave it alone
    local json = m.body:match("%b{}") -- tolerate HTML around the JSON
    local message = json and jsonapi.decode(json)
    handle(m.from, m.fromType == "identity", message)
    -- Also in DRY_RUN: a processed SyncFriends mail is not handled again.
    print((mail.trashMessage(msgId) and "" or "FAILED: ") .. "move mail " .. msgId .. " to trash")
end

-- Notices that we were offline: first run since RetroShare started (globals of
-- a script persist between runs) or no run for AWAKE_GAP (e.g. the machine slept).
local function noteRun()
    local now = os.time()
    local last = store.get("lastRun")
    local fresh = not SyncFriendsRunning
    SyncFriendsRunning = true
    if fresh or (last and now - last > AWAKE_GAP) then store.set("wokeAt", now) end
    store.set("lastRun", now)
end

-- Entry point ------------------------------------------------------------------
if args and args.selftest then
    -- Test run with simulated args (always read-only): only shows what would happen.
    dryRun, selftest = true, true
    print("SyncFriends | selftest: read-only, nothing is sent or changed")
    local t = args.selftest
    handle(t.from or ACCEPT_FROM[1], (t.fromType or "identity") == "identity", t.message)
elseif args and args.msgId then
    noteRun()
    print(("SyncFriends | incoming mail %s | %s"):format(tostring(args.msgId),
        dryRun and "DRY_RUN ON (friend add/remove only logged; mails are still sent)" or "LIVE"))
    onMail(args.msgId)
elseif args and args.list and args.list ~= 1 then
    -- Plugin builds before 2026-11-20 had one list_changed event that also fired
    -- for shared folder lists (often): only the friend list (1) matters.
else
    noteRun()
    print(("SyncFriends | checking %d partner(s) | %s"):format(#SEND_TO,
        dryRun and "DRY_RUN ON (friend add/remove only logged; mails are still sent)" or "LIVE"))
    sendList(false) -- startup, timer, friends_changed: send if changed or due
end
