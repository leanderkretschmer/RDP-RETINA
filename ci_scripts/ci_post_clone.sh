#!/bin/sh
#
# Xcode Cloud führt dieses Skript nach dem Klonen aus. FreeRDP 3 kommt aus Homebrew,
# das auf den Xcode-Cloud-Maschinen vorinstalliert ist; das Xcode-Projekt sucht die
# Header und Bibliotheken unter /opt/homebrew bzw. /usr/local.
#
set -eu

brew install freerdp
