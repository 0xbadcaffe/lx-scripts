 #######################################################
 # bspguy/lx-scripts lx_utils.sh  last update 29.03.2024 #
 #######################################################
 #!/bin/sh

Help()
{
   echo "lx-search.sh script description."
   echo
   echo "Syntax: lx-search.sh [-h|p]"
   echo "options:"
   echo "h     Print this Help."
   echo "p     Open PDF file type"
   echo
}

open_pdf_file() {
    xdg-open "$2"
}

while getopts ":hp" option; do
   case $option in
	h) 
         Help
         exit;;
    p) 
         open_pdf_file "$@"
         exit;;    
    \?)
         echo "Error: Invalid option"
         exit;;
   esac
done