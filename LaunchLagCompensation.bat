@echo off

REM Tell the user that we are running the mod

echo Launching LagCompensation

REM Run Swat4.exe from inside LagCompensation\System, so that the game
REM uses the mod's initialisation files and settings (use this to host
REM a non-dedicated server with lag compensation)

cd .\System\

..\..\Content\System\Swat4.exe

REM Tell the user that the game has exited

echo LagCompensation has exited
