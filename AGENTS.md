## Claude Session Sandbox

At the start of every session in this repo, set up a Python sandbox for Claude's own use (not for the websites below) using the steps in https://raw.githubusercontent.com/ModelEarth/cloudroot/refs/heads/main/PYTHON.md

## Start Websites

Invoke local websites on these ports using these commands. 
These run directly with system python3/node and do not use or require the Claude session sandbox above.
Open a Brave browser tab for each.

###  CloudRoot 3700

In the ../CloudRoot folder, run:

PORT=3700 node chat/server.mjs


###  Pipeline DBMonitor .NET Tradeflow 5156 for http and 7284

In the ../pipeline folder, run:

dotnet run --project DBMonitor/DBMonitor.csproj --launch-profile https

This .NET 10 app serves http on 5156 and https on 7284, as set in DBMonitor/Properties/launchSettings.json. Without `--launch-profile https`, `dotnet run` uses the http profile and serves only 5156. More details in CLAUDE.md.