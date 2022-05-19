[CmdletBinding()]

param (
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  # The highest changelist to sync up to.  If later changes are available, they are not imported
  [int] $p4changelist,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  # The Badger branch to import changes from (e.g. 'main' or 'feature_1')
  [String] $sourceBranch
)

$gitPath = "BadgerDataTest"
$depotPath = "//test-stream/$sourceBranch"

$defaultBranchName = 'main'

<#
  .SYNOPSIS
    Return the changelist that a commit imported by git p4 sync was imported from

  .PARAMETER ref
    A valid commit hash, or a ref like 'HEAD', or a branch name like 'master'

  .OUTPUTS
    An integer which is the Perforce changelist that the commit was imported from
#>
function GetChangelistFromGitCommit([String]$ref) {
  Write-Verbose "[GetChangelistFromGitCommit] Using git ref $ref"
  $log = git cat-file commit $ref | Select-String -Pattern '^ *\[git-p4: depot-paths = [^:]+: change = (\d+)\]$'
  if ($log) {
    $changelist = $log.Matches.Groups[1].Value
    Write-Verbose "[GetChangelistFromGitCommit] Changelist is $changelist"
    return [int]$changelist
  }

  Write-Verbose "[GetChangelistFromGitCommit] No matching changelist found"
  return 0
}

<#
.SYNOPSIS
  Import changes from Perforce to the given branch in Git.  Only changes up to
  the global $p4 are imported.

.DESCRIPTION
  Imports changes made to the corresponding Perforce source branch into Git, up
  to the changelist $p4changelist.  The branch will be reset to the new change at
  the conclusion of this function

.PARAMETER gitBranch
  A valid git branch name.  The commit the branch points to must have a git-p4 marker
  in its commit message.  This parameter cannot be a ref or a commit hash.

.NOTES
  If a problem is encountered during the import, the entire script will exit with
  a failed error message.
#>
function ImportChangesToGitBranch([String]$gitBranch) {
  Write-Verbose "[ImportChangesToGitBranch] Using git branch: $gitBranch"

  Write-Host "##[debug]Importing changes to git branch $gitBranch..."

  git show-ref

  # Incrementally import new changes to p4/$gitBranch
  git update-ref refs/heads/p4/$gitBranch $gitBranch
  Write-Host "##[command]git p4 sync --import-local --branch $gitBranch"
  git p4 sync --import-local --branch $gitBranch
  if ($LASTEXITCODE) {
    Write-Host "##vso[task.logissue type=error]git p4 sync failed unexpectedly.  Aborting this import."
    Write-Host "##vso[task.complete result=Failed;]git-p4 sync job failed."
    exit($LASTEXITCODE)
  }

  # limit the number of imported changes to the $p4changelist parameter.
  # Any changes added after $p4changelist are discarded.  They will be
  # imported on a subsequent call, when $p4changelist is a higher value.
  $commit = "refs/heads/p4/$gitBranch"
  while ((GetChangelistFromGitCommit($commit)) -gt $p4changelist) {
    Write-Host "##[debug]Rejecting imported commit $commit as it is for a change higher than $p4Changelist"
    $commit = git rev-parse $commit^
  }

  # reset the current state of the branch (in case some commits were thrown away in the loop above)
  git update-ref refs/heads/$gitBranch $commit
  git reset --hard $gitBranch

  # We don't need the import ref any more so remove it
  git update-ref -d refs/heads/p4/$gitBranch

  Write-Host "##[debug]Imported all changes to git branch $gitBranch"
}

function RemoveBranchStartCommit([String]$commitToRemove) {
  Write-Verbose "[RemoveBranchStartCommit] Commit to remove: $commitToRemove"
  Write-Host "##[debug]Removing the temporary commit made for the new branch"

  # Now we need to remove the extra commit we inserted which the new branch was created from.
  #
  # A simple rebase --onto ought to do the trick, right?  Well, yes that does work, but a
  # rebase also updates the commit author and date, making the first imported commits on a
  # branch inconsistent with any further imported commits.  I attempted to undo that with a
  # git filter-branch:
  #
  #   git filter-branch -f --commit-filter 'export GIT_COMMITTER_NAME=\`"`$GIT_AUTHOR_NAME\`";export GIT_COMMITTER_EMAIL=\`"`$GIT_AUTHOR_EMAIL\`";git commit-tree `$@' -- $commitToBranchFrom..$sourceBranch
  #
  # This works as expected from a regular command shell but when run from an Azure Pipelines
  # shell, the response is, "Found nothing to rewrite".  I suspect that's something to do
  # with how git filter-branch works: it shells out and runs the provided script, which I
  # can imagine Azure Pipelines might prevent for security reasons.
  #
  # we can move the commits by cherry-picking them instead.
  #
  # The expected state at this point is the new branch is checked out and the workspace is clean,
  # lets just make sure

  # Add a reference to the new import branch
  $tmpRef = 'refs/heads/p4/new-branch'
  git update-ref $tmpRef refs/heads/$sourceBranch

  # reset the new branch to the parent of the commit we're removing
  git update-ref refs/heads/$sourceBranch $commitToRemove^
  git reset --hard $sourceBranch

  # the quotation marks are needed, otherwise the commitToRemove is included in the list
  $commitsToMove = git rev-list --reverse "$commitToRemove..$tmpRef"

  $commitsToMove.ForEach( {
      $log = git cat-file commit $_ | Select-String -Pattern '^author\s(.*)\s<(.*)>\s(.*)$'
      if ($log) {
        $env:GIT_COMMITTER_NAME = $log.Matches.Groups[1].Value
        $env:GIT_COMMITTER_EMAIL = $log.Matches.Groups[2].Value
        $env:GIT_COMMITTER_DATE = $log.Matches.Groups[3].Value
        git cherry-pick $_
      }
    })

  # Clear these environment variables
  $env:GIT_COMMITTER_NAME = $null
  $env:GIT_COMMITTER_EMAIL = $null
  $env:GIT_COMMITTER_DATE = $null

  # remove the temporary branch which is no longer needed
  git update-ref -d $tmpRef
}

# The Azure Pipelines checkout task leaves the repo in a detached head state.
# I'm not quite sure how much of this is completely necessary
if (git show-ref "refs/heads/$sourceBranch") {
  Write-Verbose "[Setup] local source branch ref exists: $sourceBranch"
  git checkout $sourceBranch
  if (git show-ref "refs/remotes/origin/$sourceBranch") {
    Write-Verbose "[Setup] local and remote source branch ref exists: $sourceBranch"
    git pull origin $sourceBranch
  }
}
else {
  Write-Verbose "[Setup] local branch does not exist: $sourceBranch"
  # local branch doesn't exist
  if (git show-ref "refs/remotes/origin/$sourceBranch") {
    Write-Verbose "[Setup] remote branch ref exists: $sourceBranch"
    git checkout $sourceBranch
    git pull origin $sourceBranch
  }
  else {
    Write-Verbose "[Setup] local and source branch ref does not exist: $sourceBranch"
    # no remote branch either.  Create a new local branch
    git checkout -b $sourceBranch
  }
}

Write-Host "##[debug]Starting import for submodule gitPath $gitPath and depot path $depotPath"

if (!(Test-Path -Path "$gitPath/.git")) {
  Write-Host "##[debug]Initializing submodule..."
  git submodule update --init --checkout $gitPath

  $cwd = Get-Location

  Push-Location "$gitPath"

  # Configure the types that use Large File Storage
  $gitp4Config = Join-Path -Path (Get-Location).Path -ChildPath 'resource_packs' 'badger' 'git_configs' 'git-p4.section'
  git config include.path $gitp4Config

  # git-p4 needs to know where to import the LFS objects
  $gitLfsStoragePath = Join-Path $cwd.Path -ChildPath '.git\modules' "$gitPath" 'lfs'
  git config lfs.storage $gitLfsStoragePath
  Pop-Location
}

Push-Location "$gitPath"

# begin by fetching any changes from the remote.  Branch creation (if necessary)
# will be done after git p4 confirms there are 2 or more Perforce changelists to
# import.
git fetch --prune origin
git update-ref "refs/heads/$sourceBranch" "origin/$sourceBranch"
# Do not create the branch at this point.  New branches require special handling
# to deal with how git-p4 works.

$lastImportedChange = GetChangelistFromGitCommit($sourceBranch)
Write-Host "##[debug]Last imported change: $lastImportedChange"

if (($sourceBranch -eq $defaultBranchName) -and (0 -eq $lastImportedChange)) {
  Write-Host "##[debug]This repository is empty.  Importing all changes up to $p4Changelist"
  # New repo.  Import all commits from Perforce to the master git branch
  Write-Host "##[command]git p4 sync --import-local --branch $sourceBranch $depotPath@0,$p4Changelist"
  git p4 sync --import-local --branch $sourceBranch "$depotPath@0,$p4Changelist"
  if ($LASTEXITCODE) {
    Write-Host "##vso[task.logissue type=error]git p4 sync failed unexpectedly.  Aborting this import."
    Write-Host "##vso[task.complete result=Failed;]git-p4 sync job failed."
    exit($LASTEXITCODE)
  }
  git update-ref "refs/heads/$sourceBranch" "p4/$sourceBranch"
}
elseif (($sourceBranch -ne $defaultBranchName) -and (!(git show-ref $sourceBranch))) {
  # This is a new branch, set up git-p4 for it.
  Write-Host "##[debug]This is a new work branch."

  $p4changes = p4 changes -r -m 2 "$depotPath/..."
  if ($p4changes.count -lt 2) {
    # The main Badger data branches take several minutes to complete their initial import.
    # We only want to pay that cost once so if there are 0 or 1 submits to the branch, skip
    # it.  After there are two commits, we can import it and create the branch in git.
    Write-Host "##vso[task.logissue type=warning]Branch $depotPath is missing or has only its initial changelist, so it cannot be added to Git yet.  Skipping this submodule."
    Pop-Location
    return
  }
  else {
    # there are at least two changes on this branch.  Check the 2nd one has a
    # number less than or equal to $p4Changelist.  If it does not, stop at this
    # point as we won't be able to create the branch yet.
    if ($p4changes[1] -match 'Change (\d+)') {
      if ([int]$Matches[1] -gt $p4Changelist) {
        Write-Host "##vso[task.logissue type=warning]Branch $depotPath exists but has no importable commit at changelist $p4Changelist so it cannot be added to Git yet.  Skipping this submodule."
        Pop-Location
        return
      }
    }

    if ($p4changes[0] -match 'Change (\d+)') {
      $firstChangeOnNewBranch = [int]$Matches[1]
      Write-Host "##[debug]First changelist on this branch is $firstChangeOnNewBranch"
    }
    else {
      Write-Host "##vso[task.logissue type=error]Unable to find the first change on the new branch"
      Pop-Location
      return
    }

    $p4interchanges = p4 interchanges -r -S $depotPath
    if ($p4interchanges.count -ne 0) {
      Write-Host "##vso[debug]The new stream has unintegrated changes from its parent"
      # This means that the parent stream (main) has changes that have not been integrated
      # to the new child stream.  We need to roll back the branch point to the last change
      # that *was* integrated
      if ($p4interchanges[0] -match 'Change (\d+)') {
        $firstChangeOnNewBranch = [int]$Matches[1] - 1
        Write-Host "##[debug]Last revision integrated to the new stream is $firstChangeOnNewBranch"
      }
      else {
        Write-Host "##vso[task.logissue type=error]Unable to find the correct branch point"
        Pop-Location
        return
      }
    }
  }

  # Import any unimported changes to the base branch.  This won't be do anything most
  # of the time, but if any changes are missing from the base branch at this point,
  # it will cause a problem.

  # Make sure the branch is pointing to the same commit as the remote
  git update-ref refs/heads/$defaultBranchName origin/$defaultBranchName

  Write-Host "##[debug]Importing changes from the base branch $defaultBranchName..."
  # Currently any changes imported to the base branch after the new branch was created
  # are not pushed to the remote. They will be imported when the base branch is next
  # updated.
  ImportChangesToGitBranch($defaultBranchName)
  Write-Host "##[debug]Base branch import is complete"

  $commitToBranchFrom = $defaultBranchName
  Write-Host "##[debug]commit is $commitToBranchFrom"
  # Find the point where the new branch was created.
  while ((GetChangelistFromGitCommit($commitToBranchFrom)) -gt $firstChangeOnNewBranch) {
    Write-Host "##[debug]rejected commit $commitToBranchFrom as it is for a changelist ahead of the branch point $firstChangeOnNewBranch."
    $commitToBranchFrom = git rev-parse $commitToBranchFrom^
  }

  Write-Host "##[debug] new branch will be created at commit $commitToBranchFrom"

  # sync the workspace before doing the checkout the $commitToBranchFrom may have
  # changed due to the above logic
  git reset --hard $commitToBranchFrom

  # create the new branch at the highest change from the base branch
  git checkout -b $sourceBranch $commitToBranchFrom

  Write-Host "##[debug]Creating dummy commit"
  # add a commit to the new branch so git p4 knows where to start importing
  # to the new branch without having to create the initial unparented commit,
  # which can be very time-consuming
  git commit --allow-empty -m "[git-p4: depot-paths = \`"$depotPath/\`"`: change = $firstChangeOnNewBranch]"
  $branchStart = git rev-parse HEAD

  Write-Host "##[debug]Importing changes from the source branch $sourceBranch..."
  ImportChangesToGitBranch($sourceBranch)
  Write-Host "##[debug]$sourceBranch branch import is complete"

  RemoveBranchStartCommit($branchStart)

  Write-Host "##[debug]New branch creation complete"
}
else {
  ImportChangesToGitBranch($sourceBranch)
}

# push the imported changes to the remote repo.  This should *never* fail because
# there can only be a single instance of this pipeline running and this script is
# the only place the git repo is updated from
git push origin $sourceBranch

Pop-Location

# add the submodule changes to the parent project.  This will have no effect
# if there were no updates to the submodule
git add $gitPath

Write-Host "##[debug]Finished import for submodule gitPath $gitPath and depot path $depotPath"

if (($env:BUILD_REASON -eq 'Manual') -and (!(git status --short --ignore-submodules=none))) {
  # when this pipeline is triggered manually, there may not be any changes, so
  # don't make a dummy commit.  When the pipeline is triggered by a Perforce
  # commit, at least one submodule will be updated, so we'll always want to
  # make a new commit to Badger.
  Write-Host "##[debug]No changes. Skipping commit stage."
  return
}

# Get submission metadata
$author_name = p4 -ztag -F "%user%" describe -s $p4changelist
$author_email = p4 -ztag -F "%Email%" user -o $author_name
$timestamp = p4 -ztag -F "%time%" describe -s $p4changelist
$description = (p4 -ztag -F "%desc%" describe -s $p4changelist).Trim() -replace '"','\"'

# Set the user name and email for the committer info.  If these values are passed
# on the git commit command line, they will supersede the author name and email,
# which I don't want.
git config --local user.name 'BBI-BadgerBuild'
git config --local user.email 'badgerbuild@blackbirdinteractive.com'
git commit --author="$author_name <$author_email>" --date=$timestamp -m "[CL $p4changelist] $description"

$pushAttempts = 3
do {
  $pushAttempts--
  try {
    # Fetch updates from the remote, rebase the commit we just made on it,
    # and push the branch.  This takes 2-4 seconds, during which time another
    # commit may be pushed to the remote.  If that happens, our push will be
    # rejected.  Just re-fetch and try again.  The chances of 3 consecutive
    # pushes failing are small enough that we can disregard the possibility.
    git fetch origin
    git rebase "origin/$sourceBranch"
    git push -u origin $sourceBranch
    Write-Host "##[debug]Badger was updated successfully with new submodules"
    return # completed successfully
  }
  catch {
    Write-Host "##vso[task.logissue type=warning]git push failed because the remote repo was updated during the rebasing operation."
    $timeDelayInSeconds = Get-Random -Maximum 9 -Minimum 3
    Start-Sleep -Seconds $timeDelayInSeconds
  }
} while ($pushAttemps -ne 0)

Write-Host "##vso[task.logissue type=error]We were unable to update the remote Badger repo after 3 push attempts."
Write-Host "##vso[task.complete result=Failed;]Failed to push changes to main Badger repo."
