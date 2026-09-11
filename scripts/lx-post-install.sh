#!/bin/bash

# using one liner so you can easily comment out whatever you want
sudo apt install -y plocate           
sudo apt install -y cpuinfo
sudo apt install -y cpu-checker
sudo apt install -y neofetch
sudo apt install -y htop
sudo apt install -y gedit
sudo apt install -y bashtop
sudo apt install -y flex
sudo apt install -y bison
sudo apt install -y boxes
sudo apt install -y minicom
sudo apt install -y dkms
sudo apt install -y vim

# Add support for accessing ttyUSB[X] without root previleges
stat /dev/ttyUSBX
sudo usermod -a -G dialout



# clean up
sudo apt install -f
sudo apt autoremove
sudo apt autoclean
sudo apt clean

echo "###################################"
echo "###### lx_post_install DONE! ######"
echo "###################################"
