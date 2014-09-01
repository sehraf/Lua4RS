function getVersionNumber( s ) 
	b, e = string.find(s, "Revision")

	-- check for ':'
	x = s:sub(e + 1, e + 1)
	if x == ":" then 
		e = e + 3
	else
		e = e + 2 
	end

	-- revision starts at e  and is usually 4 characters long
	rev = s:sub(e, e + 3)

	return tonumber(rev)
end

function getName( id )
	return peers.getPeerName( id )
end

rs.clear()

-- down, up = disc.getWaitingDiscCount()
-- rs.print("waiting discovery down=" .. down .. " up=" .. up)

versions = disc.getDiscVersions()
for k, v in pairs(versions) do
	rev = getVersionNumber(v)
	if rev ~= 0 then
		rs.print(getName(k) .. " is using rev: " .. rev)
	end
end