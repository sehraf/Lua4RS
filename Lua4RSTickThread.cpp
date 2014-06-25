#include <ctime>
#include <unistd.h>

#include "Lua4RSTickThread.h"
#include "Lua/LuaCore.h"
#include "Lua/LuaEvent.h"

uint    tickIntervalInSeconds       = 1;
uint    sleepPeriodInMilliseconds   = 50;

uint    secondsToStarUpEvent        = 5;

Lua4RSTickThread::Lua4RSTickThread() :
    RsThread(),
    _lastRun( time(0) ),
    _initTime( time(0) ),
    _startUpEventTriggered( false )
{
}

void Lua4RSTickThread::run()
{
    while(isRunning())
    {
        // tick each X second
        // wait secondsToStarUpEvent to let things settle down
        if(_startUpEventTriggered && _lastRun + tickIntervalInSeconds <= time(0))
        {
            LuaEvent e;
            e.eventId = L4R_TIMERTICK;
            e.timeStamp = QDateTime::currentDateTime();
            e.dataParm = new QSettings();
            e.dataParm->setValue("testKey", "testValue");

            LuaCore::getInstance()->processEvent(e);

            _lastRun = time(0);
        }

        // start up event
        if(!_startUpEventTriggered && _initTime + secondsToStarUpEvent <= time(0))
        {
            LuaEvent e;
            e.eventId = L4R_STARTUP;
            e.timeStamp = QDateTime::currentDateTime();

            LuaCore::getInstance()->processEvent(e);

            _startUpEventTriggered = true;
        }

        // sleep X ms
        usleep(1000 * sleepPeriodInMilliseconds);
    }
}
