Set-StrictMode -Version Latest

function Get-ArchitectEpicSummary {
    param([AllowNull()] [string] $Body)
    $text = if ($null -eq $Body) { "" } else { $Body }
    $match = [regex]::Match(
        $text,
        '(?ims)^##\s+Goal[ \t]*(?:\r?\n|[ \t]{2,})(?<body>.*?)(?=\r?\n##\s|[ \t]{2,}##\s|\z)'
    )
    if (-not $match.Success) { return "No Goal summary available." }
    $paragraph = [Collections.Generic.List[string]]::new()
    foreach ($line in @($match.Groups["body"].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($paragraph.Count -gt 0) { break }
            continue
        }
        $paragraph.Add($line.Trim())
    }
    $summary = ([string]::Join(" ", $paragraph) -replace '\s+', ' ').Trim()
    if (-not $summary) { return "No Goal summary available." }
    if ($summary.Length -gt 240) { return $summary.Substring(0, 237).TrimEnd() + "..." }
    $summary
}

function Get-ArchitectEpicOption {
    param($Epic, [object[]] $Children)
    $all = @($Children)
    $open = @($all | Where-Object { "$($_.state)".ToLowerInvariant() -eq "open" })
    $closed = @($all | Where-Object { "$($_.state)".ToLowerInvariant() -eq "closed" })
    $labelCounts = @(
        $open | ForEach-Object { @($_.labels) } |
        ForEach-Object { "$($_.name)" } |
        Group-Object -Property { $_ } |
        Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } }
    )
    $warnings = [Collections.Generic.List[string]]::new()
    foreach ($signal in @(
        @{ label = "decision-needed"; text = "needs a human decision" },
        @{ label = "human-task"; text = "requires human-led work" },
        @{ label = "status:blocked"; text = "blocked" },
        @{ label = "active"; text = "active" },
        @{ label = "status:review"; text = "in review" },
        @{ label = "status:ready"; text = "ready" }
    )) {
        $count = @($open | Where-Object {
            @($_.labels | ForEach-Object { $_.name }) -contains $signal.label
        }).Count
        if ($count -gt 0) { $warnings.Add("$count $($signal.text)") }
    }
    $missingSize = @($open | Where-Object {
        @($_.labels | ForEach-Object { $_.name } | Where-Object { $_ -match '^size:' }).Count -eq 0
    }).Count
    $missingPriority = @($open | Where-Object {
        @($_.labels | ForEach-Object { $_.name } | Where-Object { $_ -match '^priority:' }).Count -eq 0
    }).Count
    $missingLifecycle = @($open | Where-Object {
        @($_.labels | ForEach-Object { $_.name } | Where-Object {
            $_ -in @("status:ready", "active", "status:review", "status:blocked")
        }).Count -eq 0
    }).Count
    if ($missingSize -gt 0) { $warnings.Add("$missingSize missing size") }
    if ($missingPriority -gt 0) { $warnings.Add("$missingPriority missing priority") }
    if ($missingLifecycle -gt 0) { $warnings.Add("$missingLifecycle without lifecycle state") }
    [pscustomobject]@{
        number = [int] $Epic.number
        title = "$($Epic.title)"
        url = "$($Epic.html_url)"
        summary = Get-ArchitectEpicSummary "$($Epic.body)"
        total = $all.Count
        open = $open.Count
        closed = $closed.Count
        labelCounts = @($labelCounts)
        warnings = @($warnings)
    }
}

function Get-ArchitectDiscussionScope {
    param([AllowNull()] [string] $Body)
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches(
        $(if ($null -eq $Body) { "" } else { $Body }),
        '<!--\s*fingvibe:(task|epic)=(\d+)\s*-->'
    )) {
        $matches.Add([pscustomobject]@{
            kind = $match.Groups[1].Value
            number = [int] $match.Groups[2].Value
        })
    }
    foreach ($match in [regex]::Matches(
        $(if ($null -eq $Body) { "" } else { $Body }),
        '<!--\s*fingvibe-agent3-discussion:(task|epic)-(\d+)\s*-->'
    )) {
        $matches.Add([pscustomobject]@{
            kind = $match.Groups[1].Value
            number = [int] $match.Groups[2].Value
        })
    }
    $unique = @($matches | Sort-Object kind, number -Unique)
    if ($unique.Count -eq 0) { return [pscustomobject]@{ found = $false; ambiguous = $false } }
    if ($unique.Count -ne 1) {
        return [pscustomobject]@{
            found = $true
            ambiguous = $true
            scopes = @($unique)
            reason = "Discussion contains conflicting task/Epic markers."
        }
    }
    [pscustomobject]@{
        found = $true
        ambiguous = $false
        kind = $unique[0].kind
        number = $unique[0].number
    }
}

function Get-ArchitectDeveloperScope {
    param([AllowNull()] [string] $Body)
    $matches = @([regex]::Matches(
        $(if ($null -eq $Body) { "" } else { $Body }),
        '<!--\s*fingvibe:epic=(\d+)\s+developer=developer-(\d+)\s*-->'
    ))
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{ found = $false; ambiguous = $false }
    }
    $scopes = @($matches | ForEach-Object {
        [pscustomobject]@{
            epic = [int] $_.Groups[1].Value
            developer = [int] $_.Groups[2].Value
        }
    } | Sort-Object epic, developer -Unique)
    if ($scopes.Count -ne 1) {
        return [pscustomobject]@{
            found = $true
            ambiguous = $true
            reason = "Discussion contains conflicting per-Developer markers."
        }
    }
    [pscustomobject]@{
        found = $true
        ambiguous = $false
        epic = $scopes[0].epic
        developer = $scopes[0].developer
    }
}

function Get-ArchitectDeveloperPlan {
    param([object[]] $Discussions, [int] $Epic, [int] $DeveloperCount)
    if ($DeveloperCount -lt 1) {
        return [pscustomobject]@{
            question = "How many Developers will work on Epic #${Epic}?"
            entries = @()
            blockers = @()
        }
    }
    $entries = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[object]]::new()
    foreach ($number in 1..$DeveloperCount) {
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($discussion in @($Discussions)) {
            $scope = Get-ArchitectDeveloperScope "$($discussion.body)"
            if (-not $scope.found) { continue }
            if ($scope.ambiguous) {
                $blockers.Add([pscustomobject]@{
                    discussion = $discussion.number
                    url = "$($discussion.url)"
                    reason = $scope.reason
                })
                continue
            }
            if ($scope.epic -eq $Epic -and $scope.developer -eq $number) {
                if ("$($discussion.category.name)" -cne "🤖 Agent logs") {
                    $blockers.Add([pscustomobject]@{
                        discussion = $discussion.number
                        url = "$($discussion.url)"
                        reason = "Developer $number log uses the wrong category."
                    })
                    continue
                }
                $matches.Add($discussion)
            }
        }
        if ($matches.Count -eq 0) {
            $entries.Add([pscustomobject]@{
                action = "create"
                epic = $Epic
                developer = $number
            })
        } elseif ($matches.Count -eq 1 -and -not [bool] $matches[0].closed) {
            $entries.Add([pscustomobject]@{
                action = "reuse"
                epic = $Epic
                developer = $number
                discussion = $matches[0].number
                id = "$($matches[0].id)"
                url = "$($matches[0].url)"
            })
        } else {
            $blockers.Add([pscustomobject]@{
                discussion = if ($matches.Count -eq 1) { $matches[0].number } else { $null }
                url = if ($matches.Count -eq 1) { "$($matches[0].url)" } else { $null }
                reason = "Epic #$Epic Developer $number has a closed or duplicate log mapping."
            })
        }
    }
    [pscustomobject]@{
        question = $null
        entries = @($entries)
        blockers = @($blockers)
    }
}

function Get-ArchitectOpenDiscussionCounts {
    param([object[]] $Discussions)
    @(
        $Discussions |
        Where-Object { -not [bool] $_.closed } |
        Group-Object -Property { "$($_.category.name)" } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{ category = $_.Name; count = $_.Count }
        }
    )
}

function Get-ArchitectDiscussionPlan {
    param(
        [object[]] $Discussions,
        [object[]] $Issues,
        [object[]] $EpicChildren,
        [int] $SelectedEpic
    )
    $scoped = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[object]]::new()
    foreach ($discussion in @($Discussions)) {
        $scope = Get-ArchitectDiscussionScope "$($discussion.body)"
        if (-not $scope.found) {
            if (-not [bool] $discussion.closed -and
                "$($discussion.category.name)" -in @(
                    "🛠️ Task conversations",
                    "🧭 Epic coordination"
                )) {
                $blockers.Add([pscustomobject]@{
                    discussion = $discussion.number
                    url = "$($discussion.url)"
                    kind = $null
                    number = $null
                    scopes = @()
                    reason = "Open task/Epic Discussion has no canonical scope marker."
                })
            }
            continue
        }
        if ($scope.ambiguous) {
            $blockers.Add([pscustomobject]@{
                discussion = $discussion.number
                url = "$($discussion.url)"
                kind = $null
                number = $null
                scopes = @($scope.scopes)
                reason = $scope.reason
            })
            continue
        }
        $expectedCategory = if ($scope.kind -eq "task") {
            "🛠️ Task conversations"
        } else {
            "🧭 Epic coordination"
        }
        if ("$($discussion.category.name)" -cne $expectedCategory) {
            $blockers.Add([pscustomobject]@{
                discussion = $discussion.number
                url = "$($discussion.url)"
                kind = $scope.kind
                number = $scope.number
                scopes = @()
                reason = "Wrong category '$($discussion.category.name)' for $($scope.kind) marker."
            })
            continue
        }
        $scoped.Add([pscustomobject]@{ discussion = $discussion; scope = $scope })
    }
    foreach ($group in @($scoped | Group-Object {
        "$($_.scope.kind)-$($_.scope.number)"
    })) {
        if ($group.Count -le 1) { continue }
        foreach ($item in @($group.Group)) {
            $blockers.Add([pscustomobject]@{
                discussion = $item.discussion.number
                url = "$($item.discussion.url)"
                kind = $item.scope.kind
                number = $item.scope.number
                scopes = @()
                reason = "Duplicate $($item.scope.kind) Discussion mapping for #$($item.scope.number)."
            })
        }
    }
    $duplicates = @($blockers | Where-Object {
        "$($_.reason)".StartsWith("Duplicate ")
    } | ForEach-Object { [int] $_.discussion })
    $close = [Collections.Generic.List[object]]::new()
    $open = [Collections.Generic.List[object]]::new()
    foreach ($item in @($scoped)) {
        if ($duplicates -contains [int] $item.discussion.number) { continue }
        $issue = @($Issues | Where-Object { [int] $_.number -eq $item.scope.number } | Select-Object -First 1)
        if ($issue.Count -ne 1) {
            $blockers.Add([pscustomobject]@{
                discussion = $item.discussion.number
                url = "$($item.discussion.url)"
                kind = $item.scope.kind
                number = $item.scope.number
                scopes = @()
                reason = "Mapped issue #$($item.scope.number) is unavailable."
            })
            continue
        }
        $issueState = "$($issue[0].state)".ToLowerInvariant()
        if ($item.scope.kind -eq "task") {
            if ($issueState -eq "closed") {
                if (-not [bool] $item.discussion.closed) {
                    $close.Add([pscustomobject]@{
                        kind = "task"
                        number = $item.scope.number
                        discussion = $item.discussion.number
                        url = "$($item.discussion.url)"
                        id = "$($item.discussion.id)"
                    })
                }
            } else {
                $open.Add([pscustomobject]@{
                    kind = "task"
                    number = $item.scope.number
                    discussion = $item.discussion.number
                    url = "$($item.discussion.url)"
                    openTasks = 1
                    reason = "Mapped task #$($item.scope.number) is open."
                })
            }
            continue
        }
        $childSet = @($EpicChildren | Where-Object {
            [int] $_.epic -eq $item.scope.number
        } | Select-Object -First 1)
        if ($childSet.Count -ne 1) {
            $blockers.Add([pscustomobject]@{
                discussion = $item.discussion.number
                url = "$($item.discussion.url)"
                kind = $item.scope.kind
                number = $item.scope.number
                scopes = @()
                reason = "Direct-child inventory for Epic #$($item.scope.number) is unavailable."
            })
            continue
        }
        $children = @($childSet[0].children)
        $openChildren = @($children | Where-Object {
            "$($_.state)".ToLowerInvariant() -ne "closed"
        })
        if ($issueState -eq "closed" -and $openChildren.Count -eq 0) {
            if (-not [bool] $item.discussion.closed) {
                $close.Add([pscustomobject]@{
                    kind = "epic"
                    number = $item.scope.number
                    discussion = $item.discussion.number
                    url = "$($item.discussion.url)"
                    id = "$($item.discussion.id)"
                })
            }
        } else {
            $reason = if ($issueState -ne "closed") {
                "Epic #$($item.scope.number) is open."
            } else {
                "Closed Epic #$($item.scope.number) still has $($openChildren.Count) open direct child issue(s)."
            }
            $open.Add([pscustomobject]@{
                kind = "epic"
                number = $item.scope.number
                discussion = $item.discussion.number
                url = "$($item.discussion.url)"
                openTasks = $openChildren.Count
                reason = $reason
            })
        }
    }
    $selected = @($scoped | Where-Object {
        $_.scope.kind -eq "epic" -and $_.scope.number -eq $SelectedEpic
    })
    $selectedConflict = @($blockers | Where-Object {
        ($null -ne $_.number -and "$($_.kind)" -eq "epic" -and [int] $_.number -eq $SelectedEpic) -or
        ($null -ne $_.scopes -and @($_.scopes | Where-Object {
            "$($_.kind)" -eq "epic" -and [int] $_.number -eq $SelectedEpic
        }).Count -gt 0)
    })
    $selectedAction = if ($selectedConflict.Count -gt 0) {
        [pscustomobject]@{ action = "blocked"; epic = $SelectedEpic }
    } elseif ($selected.Count -eq 0) {
        [pscustomobject]@{ action = "create"; epic = $SelectedEpic }
    } elseif ($selected.Count -eq 1 -and -not [bool] $selected[0].discussion.closed) {
        [pscustomobject]@{
            action = "reuse"
            epic = $SelectedEpic
            discussion = $selected[0].discussion.number
            url = "$($selected[0].discussion.url)"
            id = "$($selected[0].discussion.id)"
        }
    } else {
        $blockers.Add([pscustomobject]@{
            discussion = if ($selected.Count -eq 1) { $selected[0].discussion.number } else { $null }
            url = if ($selected.Count -eq 1) { "$($selected[0].discussion.url)" } else { $null }
            kind = "epic"
            number = $SelectedEpic
            scopes = @()
            reason = "Selected Epic #$SelectedEpic has a closed or ambiguous coordination mapping."
        })
        [pscustomobject]@{ action = "blocked"; epic = $SelectedEpic }
    }
    [pscustomobject]@{
        close = @($close)
        open = @($open)
        blockers = @($blockers)
        selected = $selectedAction
    }
}

function Get-ArchitectDiscussionInventory {
    param([string] $Repository, [scriptblock] $Api)
    $parts = $Repository.Split("/")
    if ($parts.Count -ne 2) { throw "Invalid repository '$Repository'." }
    $cursor = $null
    $seenCursors = @{}
    $seenDiscussions = @{}
    $discussions = [Collections.Generic.List[object]]::new()
    $repositoryData = $null
    do {
        $query = 'query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){id nameWithOwner discussionCategories(first:100){nodes{id name} pageInfo{hasNextPage}} discussions(first:100,after:$cursor,orderBy:{field:CREATED_AT,direction:ASC}){nodes{id number title body url closed closedAt stateReason category{id name}} pageInfo{hasNextPage endCursor}}}}'
        $data = & $Api $query @{ owner = $parts[0]; name = $parts[1]; cursor = $cursor }
        $repositoryData = $data.repository
        if ($null -eq $repositoryData) {
            throw "Discussion repository/category inventory is incomplete."
        }
        $categoryPageInfo = $repositoryData.discussionCategories.pageInfo
        if ("$($repositoryData.nameWithOwner)" -ine $Repository -or
            -not "$($repositoryData.id)" -or
            $categoryPageInfo -isnot [Collections.IDictionary] -or
            -not $categoryPageInfo.Contains("hasNextPage") -or
            [bool] $categoryPageInfo.hasNextPage) {
            throw "Discussion repository/category inventory is incomplete."
        }
        $page = $repositoryData.discussions
        $pageInfo = $page.pageInfo
        if ($pageInfo -isnot [Collections.IDictionary] -or
            -not $pageInfo.Contains("hasNextPage")) {
            throw "Discussion inventory pagination is incomplete."
        }
        $hasNextPage = [bool] $pageInfo.hasNextPage
        foreach ($discussion in @($page.nodes)) {
            if (-not "$($discussion.id)" -or $seenDiscussions.ContainsKey("$($discussion.id)")) {
                throw "Duplicate or incomplete Discussion inventory entry."
            }
            $seenDiscussions["$($discussion.id)"] = $true
            $discussions.Add($discussion)
        }
        $next = "$($pageInfo.endCursor)"
        if ($hasNextPage) {
            if (-not $next -or $seenCursors.ContainsKey($next)) {
                throw "Invalid Discussion inventory cursor."
            }
            $seenCursors[$next] = $true
        }
        $cursor = $next
    } while ($hasNextPage)
    [pscustomobject]@{
        repositoryId = "$($repositoryData.id)"
        categories = @($repositoryData.discussionCategories.nodes)
        discussions = @($discussions)
    }
}

Export-ModuleMember -Function @(
    "Get-ArchitectEpicSummary",
    "Get-ArchitectEpicOption",
    "Get-ArchitectDiscussionScope",
    "Get-ArchitectDeveloperScope",
    "Get-ArchitectDeveloperPlan",
    "Get-ArchitectOpenDiscussionCounts",
    "Get-ArchitectDiscussionPlan",
    "Get-ArchitectDiscussionInventory"
)
