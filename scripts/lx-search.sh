 #######################################################
 # bspguy/lx-scripts lx_git.sh  last update 16.03.2024 #
 #######################################################
 #!/bin/sh

Help()
{
   echo "lx-search.sh script description."
   echo
   echo "Syntax: lx-search.sh [-h|s|f|p]"
   echo "options:"
   echo "h     Print this Help."
   echo "s     Find string withing file"
   echo "f     Find string in file name"
   echo "p     Search using plocate"
   echo
}

find_string_in_file() {

    grep -Rnw ./  -e "'$2'"

}

find_string_in_file_name() {
    find . -maxdepth 1 -name "*$2*" -print
}

search_using_plocate() {
    plocate "$2"
}

while getopts ":hsfp" option; do
   case $option in
	h) 
         Help
         exit;;
	s) 
         find_string_in_file "$@"
         exit;;
	f) 
         find_string_in_file_name "$@"
         exit;;    

    p) 
         search_using_plocate "$@"
         exit;;    
    \?)
         echo "Error: Invalid option"
         exit;;
   esac
done