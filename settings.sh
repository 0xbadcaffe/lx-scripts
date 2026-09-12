#!/bin/sh

LX_SCRIPT_LOC=$PWD

#
# Add the lx-scripts to the user's search path
#
PATH="${LX_SCRIPT_LOC}/scripts/:${PATH}"

#
# Check for "." or ".\" in the path - it's broken
#
echo "${PATH}" | tr ":" "\n" | grep '^\./*$' > /dev/null && 
	echo "WARNING: '.' detected in PATH - fixing it." 1>&2
PATH=`echo ${PATH} | tr ":" "\n" | grep -v '^\./*$' | tr "\n" ":"`

# Strip any trailing or multi-colons - they are interpreted as '.'
PATH=$(echo ${PATH} | sed -e 's/:*$//g' -e 's/::*/:/g')

export PATH

echo LX Scripts environment set to \'${LX_SCRIPT_LOC}\'

for s in /bin/sh sh; do
	if ! $s --version 4>/dev/null | grep -q "^GNU bash"; then
		echo "WARNING: $s is not bash or bash is not version 4 or upper! "
		echo "bash version 4 is needed for using associative Arrays.
		echo "bash is the recommended shell. Please set your default shell to bash."
		break
	fi
done

if ! echo $SHELL | grep -q "bash"; then
	echo "WARNING: $SHELL is not bash! "
	echo "/bin/bash is lx-scripts recommended SHELL variable. Please set your SHELL variable to /bin/bash."
fi