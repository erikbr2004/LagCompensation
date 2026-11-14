@echo off

REM Tell the user that we are running the mod's dedicated server

echo Launching LagCompensation dedicated server

REM Run Swat4DedicatedServer.exe from inside LagCompensation\System, so that
REM the server uses the mod's initialisation files and settings

cd .\System\

..\..\Content\System\Swat4DedicatedServer.exe

REM Tell the user that the server has exited

echo LagCompensation dedicated server has exited
