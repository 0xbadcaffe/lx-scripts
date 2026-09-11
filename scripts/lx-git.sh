 #######################################################
 # bspguy/lx-scripts lx-git.sh  last update 24.12.2021 #
 #######################################################
 #!/bin/sh

#!/bin/bash

declare -A actions

actions[start]="echo Starting the process..."
actions[stop]="echo Stopping the process..."
actions[restart]="echo Restarting the process..."

param="$1"

if [[ -n "${actions[$param]}" ]]; then
    eval "${actions[$param]}"
else
    echo "Invalid option. Usage: $0 {start|stop|restart}"
fi



usage() {
    echo "Script Usage:"
    echo "$0 -start   Start the process."
    echo "$0 -stop    Stop the process."
    echo "$0 -restart Restart the process."
    echo "$0 -h       Display this help message."
    echo "Example:"
    echo "$0 -start"
    exit 1
}


Help()
{
   echo "lx-git.sh script description."
   echo
   echo "Syntax: lx-git-utils.sh [-h|s|a]"
   echo "options:"
   echo "h     Print this Help."
   echo "s     Shows the git repo status"
   echo "a     Add new files, Commit and push."
   echo
}

Status()
{
	if [ $(git status --porcelain | wc -l) -eq "0" ]; then 
		echo "  🟢 Git repo is clean."
	else 
		echo "  🔴 Git repo dirty. Quit."
  	exit 1
	fi
}

#git diff

#Shows the changes between the working directory and the index. 
#This shows what has been changed, but is not staged for a commit.

#git diff --cached

#Shows the changes between the index and the HEAD (which is the last commit on this branch). 
#This shows what has been added to the index and staged for a commit.

#git diff HEAD

#Shows all the changes between the working directory and HEAD (which includes changes in the index). 
#This shows all the changes since the last commit, whether or not they have been staged for commit or not.

Diff()
{
   git diff --cached
}

Fetch()
{
	git fetch
}

Log()
{
	git log
}

ListRemoteGitTags()
{
	git tag -n
}

ListRemoteBranches()
{
   git show-branch -r
}

CheckOutNewBranch()
{
	git checkout -b new_branch_name
 	git push --set-upstream origin new_branch_name
}

CheckOutRemoteTag()
{
	git checkout -b new_local_branch_name tags/remote_tag_name
}

CheckOutRemoteBranch()
{
   git fetch origin
   git checkout --track origin/remote_branch_name
}

Commit()
{
   git commit -m "updated files :)"
}

AddCommitPush()
{
	git add .  &&  git commit -m "Updated lx-git script" && git push
}


MirrorGitBareRepo()
{
	git clone --bare --mirror  git@github.com:analogdevicesinc/libiio.git
	#then 
	git clone /path/to/bare/
}

CrateTag()
{
    git tag -a v1.4 -m "my version 1.4"
}

PushTags()
{
   git push origin --tags
}

Push()
{
	git push
}

Log()
{
   git log -v HEAD..origin/main
}

# Get the options
while getopts ":hsal" option; do
   case $option in
	h) # display Help
         Help
         exit;;
	s) # show git status
         Status
         exit;;
	a) # Add new files, Commit and push
         AddCommitPush
         exit;;
	l) # log commit diff
         Log
         exit;;         
     \?) # incorrect option
         echo "Invalid option. Usage: $0 {start|stop|restart}"
         exit;;
   esac
done

Help
exit;

echo "
._____. ._____. .____________________. ._____. ._____.
| ._. | | ._. | | .________________. | | ._. | | ._. |
| !_| |_|_|_! | | !________________! | | !_| |_|_|_! |
!___| |_______! !____________________! !___| |_______!
.___|_|_| |________________________________|_|_| |___.
| ._____| |____________________________________| |_. |
| !_! | | |                                | | ! !_! |
!_____! | | If you are reading this        | | !_____!
._____. | | then somting worng has happend | | ._____.
| ._. | | |                                | | | ._. |
| | | | | |                                | | | | | |
| !_! | | |                                | | ! !_! |
!_____! | |                                | | !_____!
._____. | |                                | | ._____.
| ._. | | |                                | | | ._. |
| !_| |_|_|________________________________| |_|_|_! |
!___| |____________________________________| |_______!
.___|_|_| |___. .____________________. .___|_|_| |___.
| ._____| |_. | | .________________. | | ._____| |_. |
| !_! | | !_! | | !________________! | | !_! | | !_! |
!_____! !_____! !____________________! !_____! !_____!
"



###############################

#!/bin/bash

Help() {
    echo "lx-git.sh script description."
    echo
    echo "Syntax: lx-git.sh [-h|-s|-d|-f|-c|-p|-t|-lt|-lb|-co|-cot|-cob]"
    echo "Options:"
    echo "  -h       Print this help message."
    echo "  -s       Show the git repo status."
    echo "  -d       Show changes between working directory and index."
    echo "  -f       Fetch latest changes from remote."
    echo "  -c       Commit changes."
    echo "  -p       Push changes to remote."
    echo "  -t       Create a new tag."
    echo "  -lt      List all remote tags."
    echo "  -lb      List all remote branches."
    echo "  -co      Create and switch to a new branch."
    echo "  -cot     Checkout a remote tag."
    echo "  -cob     Checkout a remote branch."
    exit 1
}

Status() {
    if [ $(git status --porcelain | wc -l) -eq "0" ]; then 
        echo "  🟢 Git repo is clean."
    else 
        echo "  🔴 Git repo dirty. Quit."
        exit 1
    fi
}

Diff() {
    git diff --cached
}

Fetch() {
    git fetch
}

Commit() {
    git add . && git commit -m "Updated lx-git script"
}

Push() {
    git push
}

CreateTag() {
    echo -n "Enter tag name: "
    read tag_name
    git tag -a "$tag_name" -m "Tag $tag_name created"
}

ListRemoteTags() {
    git tag -n
}

ListRemoteBranches() {
    git branch -r
}

CheckOutNewBranch() {
    echo -n "Enter branch name: "
    read branch_name
    git checkout -b "$branch_name"
    git push --set-upstream origin "$branch_name"
}

CheckOutRemoteTag() {
    echo -n "Enter tag name: "
    read tag_name
    git checkout -b "$tag_name" "tags/$tag_name"
}

CheckOutRemoteBranch() {
    echo -n "Enter branch name: "
    read branch_name
    git fetch origin
    git checkout --track "origin/$branch_name"
}

while getopts ":hsdfcptltlbco:cot:cob:" option; do
    case $option in
        h) Help ;;
        s) Status ;;
        d) Diff ;;
        f) Fetch ;;
        c) Commit ;;
        p) Push ;;
        t) CreateTag ;;
        lt) ListRemoteTags ;;
        lb) ListRemoteBranches ;;
        co) CheckOutNewBranch ;;
        cot) CheckOutRemoteTag ;;
        cob) CheckOutRemoteBranch ;;
        \?) echo "Invalid option: -$OPTARG. Use -h for help." >&2
            exit 1 ;;
    esac
done

# If no options are provided, display help
if [ $OPTIND -eq 1 ]; then
    Help
fi

exit 0



1. Rename the Local Branch

If you are on the branch you want to rename:

git branch -m new-branch-name

If you are not on the branch, use:

git branch -m old-branch-name new-branch-name

2. Delete the Old Remote Branch

Push the new branch and remove the old one from the remote repository:

git push origin --delete old-branch-name

3. Push the New Branch to Remote

git push origin new-branch-name

4. Reset the Upstream Branch (if needed)

To make sure the renamed local branch tracks the remote branch:

git branch --unset-upstream
git branch --set-upstream-to=origin/new-branch-name

