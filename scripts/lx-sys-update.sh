#!/bin/bash

sudo apt update -y
apt list --upgradable #for logging
sudo apt upgrade --allow-downgrades -y
sudo apt full-upgrade --allow-downgrades -y
sudo apt dist-upgrade -y
