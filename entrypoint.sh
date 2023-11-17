#!/bin/bash

set -eo pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
default_branch=${DEFAULT_BRANCH:-$GITHUB_BASE_REF} # get the default branch from github runner env vars
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-test,dev,main}
custom_tag=${CUSTOM_TAG:-}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
git_api_tagging=${GIT_API_TAGGING:-true}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
prerelease=${PRERELEASE:-false}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
major_string_token=${MAJOR_STRING_TOKEN:-#major}
minor_string_token=${MINOR_STRING_TOKEN:-#minor}
patch_string_token=${PATCH_STRING_TOKEN:-#patch}
none_string_token=${NONE_STRING_TOKEN:-#none}
branch_history=${BRANCH_HISTORY:-compare}
# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

cd "${GITHUB_WORKSPACE}/${source}" || exit 1

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tDEFAULT_BRANCH: ${default_branch}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tGIT_API_TAGGING: ${git_api_tagging}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE: ${prerelease}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"
echo -e "\tMAJOR_STRING_TOKEN: ${major_string_token}"
echo -e "\tMINOR_STRING_TOKEN: ${minor_string_token}"
echo -e "\tPATCH_STRING_TOKEN: ${patch_string_token}"
echo -e "\tNONE_STRING_TOKEN: ${none_string_token}"
echo -e "\tBRANCH_HISTORY: ${branch_history}"

# verbose, show everything
if $verbose
then
    set -x
fi

setOutput() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="$prerelease"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    # check if ${current_branch} is in ${release_branches} | exact branch match
    if [[ "$current_branch" == "$b" ]]
    then
        pre_release="false"
    fi
    # verify non specific branch names like  .* release/* if wildcard filter then =~
    if [ "$b" != "${b//[\[\]|.? +*]/}" ] && [[ "$current_branch" =~ $b ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags

tagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+$"
preTagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)$"

# get the git refs
git_refs=
case "$tag_context" in
    *repo*)
        git_refs=$(git for-each-ref --sort=-committerdate --format '%(refname:lstrip=2)')
        ;;
    *branch*)
        git_refs=$(git tag --list --merged HEAD --sort=-committerdate)
        ;;
    * ) echo "Unrecognised context"
        exit 1;;
esac

# get the latest tag that looks like a semver (with or without v)
matching_tag_refs=$( (grep -E "$tagFmt" <<< "$git_refs") || true)
matching_pre_tag_refs=$( (grep -E "$preTagFmt" <<< "$git_refs") || true)
tag=$(head -n 1 <<< "$matching_tag_refs")
pre_tag=$(head -n 1 <<< "$matching_pre_tag_refs")

# if there are none, start tags at INITIAL_VERSION
if [ -z "$tag" ]
then
    if $with_v
    then
        tag="v$initial_version"
    else
        tag="$initial_version"
    fi
    
    if [ -z "$pre_tag" ] && $pre_release
    then
        if $with_v
        then
            pre_tag="v$initial_version"
        else
            pre_tag="$initial_version"
        fi
    fi
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 "$tag" || true )
# get current commit hash
commit=$(git rev-parse HEAD)
# skip if there are no new commits for non-pre_release
if [ "$tag_commit" == "$commit" ]
then
    echo "No new commits since previous tag. Skipping..."
    setOutput "new_tag" "$tag"
    setOutput "tag" "$tag"
    exit 0
fi

FEATURE_BRANCH=${GITHUB_HEAD_REF}
LAST_COMMIT_SHA=$(git log --format="%H" -n 1 origin/$FEATURE_BRANCH)
log=$(git log -1 --pretty=format:"%s" $LAST_COMMIT_SHA)

echo "Pre tag: $pre_tag"
echo "Tag: $tag"

is_pre_tag_newer="false"
pre_tag_without_build=${pre_tag%%-build*}
			
# Split versions into components
IFS="-." read -ra pre_tag_components <<< "$pre_tag_without_build"
IFS="-." read -ra tag_components <<< "$tag"

# Compare MAJOR, MINOR, and PATCH components
if [[ ${pre_tag_components[0]} -lt ${tag_components[0]} ]]; then
	echo "$pre_tag is older than $tag"
elif [[ ${pre_tag_components[0]} -gt ${tag_components[0]} ]]; then
	is_pre_tag_newer="true"
	echo "$pre_tag is newer than $tag"
else
	if [[ ${pre_tag_components[1]} -lt ${tag_components[1]} ]]; then
		echo "$pre_tag is older than $tag"
	elif [[ ${pre_tag_components[1]} -gt ${tag_components[1]} ]]; then
		is_pre_tag_newer="true"
		echo "$pre_tag is newer than $tag"
	else
		if [[ ${pre_tag_components[2]} -lt ${tag_components[2]} ]]; then
			echo "$pre_tag is older than $tag"
		elif [[ ${pre_tag_components[2]} -gt ${tag_components[2]} ]]; then
			is_pre_tag_newer="true"
			echo "$pre_tag is newer than $tag"
		else
			is_pre_tag_newer="false"
			echo "$pre_tag is the same as $tag"
		fi
	fi
fi

if [[ "$is_pre_tag_newer" == "true"* ]]; then
	tag=${pre_tag%%-build*}
fi 

echo "Testing: Pre tag is newer = $is_pre_tag_newer"
echo "Pre tag: $pre_tag"
echo "Tag: $tag"

case "$log" in
    *#major* ) new=$(semver -i major $tag); part="major"; pre_release="false";;
    *#minor* ) new=$(semver -i minor $tag); part="minor"; pre_release="false";;
    *#patch* ) new=$(semver -i patch $tag); part="patch"; pre_release="false";;
    * ) 
    	echo "No version tag indicated, creating a prerelease."
        if $pre_release; then
            if [[ "$is_pre_tag_equals" == "true" ]]; then 
  		        new=$(semver -i prerelease $pre_tag --preid $suffix); 
	        elif [[ "$is_pre_tag_newer" == "false" ]]; then
	            echo "Here 0"
	     	    echo "Debug before here 0: $tag"
	            
	            if [[ $pre_tag == *".0" ]]; then
	                echo "Here 0.1"
		        # If it ends with '.0', set it to '.1'
		        pre_tag="${pre_tag%.*}.1"
		        pre_tag="${pre_tag}-${suffix}.0"
		    else
		        pre_tag="${tag}-${suffix}.0"
		    fi
	                new=$(semver -i prerelease $pre_tag --preid $suffix); 
		 	part="pre-$part"
		 	
			echo "Debug new: $new"
   			echo "Debug part: $part"
			echo "Debug pretag: $pre_tag"
   			echo "Debug suffix: $suffix"
  		        
	        else  
		        new=$(semver -i prerelease $pre_tag --preid $suffix); 
	 	        part="pre-$part"
   	        fi
	    fi
    ;;
esac

echo $new

# did we get a new tag?
if [ ! -z "$new" ]
then
    # prefix with 'v'
    if $with_v
        then
	    new="v$new"
     fi
fi

if [ ! -z $custom_tag ]
then
    new="$custom_tag"
fi

# set outputs
setOutput "new_tag" "$new"
setOutput "part" "$part"
setOutput "tag" "$new" # this needs to go in v2 is breaking change
setOutput "old_tag" "$tag"

# dry run exit without real changes
if $dryrun
then
    exit 0
fi

echo "EVENT: creating local tag $new"
# create local git tag
git tag -f "$new" || exit 1
echo "EVENT: pushing tag $new to origin"

if $git_api_tagging
then
    # use git api to push
    dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
    full_name=$GITHUB_REPOSITORY
    git_refs_url=$(jq .repository.git_refs_url "$GITHUB_EVENT_PATH" | tr -d '"' | sed 's/{\/sha}//g')

    echo "$dt: **pushing tag $new to repo $full_name"

    git_refs_response=$(
    curl -s -X POST "$git_refs_url" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -d @- << EOF
{
    "ref": "refs/tags/$new",
    "sha": "$commit"
}
EOF
)

    git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

    echo "::debug::${git_refs_response}"
    if [ "${git_ref_posted}" = "refs/tags/${new}" ]
    then
        exit 0
    else
        echo "::error::Tag was not created properly."
        exit 1
    fi
else
    # use git cli to push
    git push -f origin "$new" || exit 1
fi
  
