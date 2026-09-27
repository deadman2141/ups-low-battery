# UPS Low Battery Shutdown
-Vibe Coded Locally with Qwen3.8:27b

-I wanted somthing that would send commands securly over the network, as NUT doesnt come precompiled with a SSL tunnel between server and clients.

-Simply my own ignorance has made this a requirement.

## Simple Explanation
-Utilizing BASH, Network UPS Tool (NUT) and ssh, check UPS battery charge and line in status.

-ups_low_battery.sh is the main script that listens and fires commands when the prereques met.

-It uses systemd to start at boot and run in the background.

-Runs as root on device that has the UPS/NUT installed.

## Prerequisits to Run
-This is running on a Raspberry PI, with a triplite UPS. It should be able to run on anything that has BASH, NUT and ssh.

-The ups_low_battery_targets.example is the format for user@host [command].

-Make sure the remote user has sufficaint permissions to run the said command.

-Make sure ssh keys are appropriately placed. Currently will not work with password authentication for remote hosts.

-Edit ups_low_battery.conf for your UPS name. The value should be what you set during the NUT Setup. You can check to see if your UPS is visiable by `upsc -l`

## Install Script
-Places files to correct locations for systemd (On a Raspberry PI OS)

-Sets up the systemd service

-Enables said service

## Useful commands

-sudo journalctl -u ups-low-battery -f

-Outputs `DATE TIME HOSTNAME ups_low_battery.sh: [DATE TIME] UPS state: charge=PERCENTAGE status=UPS_LINE_STATUS`

## TO DO
-Validate code to check polling location for CHARGE and STATUS are ubiquitius across vendors. Which are probably not...