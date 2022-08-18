local pr = require('litee.gh.pr')
local dv = require('litee.gh.pr.diff_view')
local noti = require('litee.gh.notifications')
local pr_handlers = require('litee.gh.pr.handlers')
local issues = require('litee.gh.issues')
local debug  = require('litee.gh.debug')

local M = {}

local commands = {
    -- use a vim.ui.select prompt to open one of the first 100 pull requests.
    {name = "GHOpenPR", callback=pr.open_pull, opts={nargs="?"}},
    -- use a vim.ui.select prompt to open one of the first 100 pull requests.
    {name = "GHOpenPR", callback = pr.open_pull, opts = {nargs="?"}},
    -- open the Pull Request panel in the side bar panel
    {name = "GHOpenToPR", callback = pr.open_to_pr, opts = {}},
    -- open the Pull Request panel in a pop out window
    {name = "GHPopOutPR", callback = pr.popout_to_pr, opts = {}},
    -- open the Commit panel in the side bar panel.
    {name = "GHOpenToCommit", callback = pr.open_to_pr_files, opts = {}},
    -- open the Commit panel in a pop out window
    {name = "GHPopOutCommit", callback = pr.popout_to_pr_files, opts = {}},
    -- collapse the node within the Pull Request panel
    {name = "GHCollapsePR", callback = pr.collapse_pr, opts = {}},
    -- expand the node within the Pull Request panel
    {name = "GHExpandPR", callback = pr.expand_pr, opts = {}},
    -- collapse the node within the Commit panel
    {name = "GHCollapseCommit", callback = pr.collapse_pr_commits, opts = {}},
    -- expand the node within the Commit panel
    {name = "GHExpandCommit", callback = pr.expand_pr_commits, opts = {}},
    -- collapse the node within the Review panel
    {name = "GHCollapseReview", callback = pr.collapse_pr_review, opts = {}},
    -- expand the node within the Review panel
    {name = "GHExpandReview", callback = pr.expand_pr_review, opts = {}},
    -- refresh all details of the PR
    {name = "GHRefreshPR", callback = pr_handlers.on_refresh, opts = {}},
    -- refresh just comments, useful to fresh convo buffers quicker.
    {name = "GHRefreshComments", callback = pr_handlers.refresh_comments, opts = {}},
    -- refresh any open issue buffers, if a PR is opened, this will be ran as part of "GHRefreshPR"
    {name = "GHRefreshIssues", callback = issues.on_refresh, opts = {}},
    -- refresh the notifications buffer if it is open.
    {name = "GHRefreshNotifications", callback = noti.on_refresh, opts = {}},
    -- start a code review
    {name = "GHStartReview", callback = pr.start_review, opts = {}},
    -- submit all pending comments in a code review
    {name = "GHSubmitReview", callback = pr.submit_review, opts = {}},
    -- delete the current code review
    {name = "GHDeleteReview", callback = pr.delete_review, opts = {}},
    -- a convenience function, immediately approve the pull request with an optional comment.
    {name = "GHApproveReview", callback = pr.immediately_approve_review, opts = {}},
    -- open the main Pull Request details convo buffer.
    {name = "GHPRDetails", callback = pr.open_pr_buffer, opts = {}},
    -- when cursor is on a commented line of a diff view, toggle the convo buffer.
    {name = "GHToggleThreads", callback = function() dv.toggle_threads(nil) end, opts = {}},
    -- when cursor is on a commented line of a diff view, move to the next convo buffer
    {name = "GHNextThread", callback = dv.next_thread, opts = {}},
    -- when cursor is on a line which can be commented in a diff view, create a comment
    {name = "GHCreateThread", callback = dv.create_comment, opts = {range=true}},
    -- close a PR and cleanup any state associated with it (happens on tab and neovim close as well)
    {name = "GHClosePR", callback = pr.close_pull, opts = {}},
    -- close the Commit panel
    {name = "GHCloseCommit", callback = function() pr.close_pr_commits(nil) end, opts = {}},
    -- close the Review panel
    {name = "GHCloseReview", callback = function () pr.close_pr_review(nil) end, opts = {}},
    -- preview the issue or pull request number under the cursor
    {name = "GHPreviewIssue", callback = issues.preview_issue_under_cursor, opts = {}},
    -- Add a label to the currently opened pull request.
    {name = "GHAddLabel", callback = pr.add_label, opts = {}},
    -- Remove a label from the currently opened pull request.
    {name = "GHRemoveLabel", callback = pr.remove_label, opts = {}},
    -- If possible, open the node under the cursor in your web browser.
    {name = "GHViewWeb", callback =  pr.open_node_url, opts = {}},
    -- Open an issue, if a number is provided it will be opened directly, if not
    -- a vim.ui.select with all repo issues is opened for selection.
    {name = "GHOpenIssue", callback = issues.open_issue, opts = {nargs="?"}},
    -- Open a PR you've been requested to review.
    {name = "GHRequestedReview", callback = pr.open_pull_requested_review_user, opts = {}},
    -- Open a PR in the open state which you have reviewed.
    {name = "GHReviewed", callback = pr.open_pull_request_reviewed_by_user, opts = {}},
    -- Search the current repo's PR's utilizing GH search queries. 
    -- Searches are always constrained to the repository Neovim is opened to.
    -- See: https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests
    {name = "GHSearchPRs", callback = pr.search_pulls, opts = {}},
    -- Search GitHub issues, this search is not constrained to any repository and 
    -- a query string should be provided
    {name = "GHSearchIssues", callback = function() issues.search_issues(false) end, opts = {}},
    -- Search GitHub issues for the current repository.
    {name = "GHSearchRepoIssues", callback = function () issues.search_issues(true) end, opts = {}},
    -- List assigned issues for the current repo.
    {name = "GHAssignedRepoIssues", callback = issues.assigned_repo_issues, opts = {}},
    -- Open a UI displaying all unread notifications for the repo gh.nvim is opened
    -- to.
    {name = "GHNotifications", callback = noti.open_notifications, opts = {}},
    -- When config["debug_logging"] is set to true, this command will open a buffer
    -- holding all git and gh cli invocations and their outputs.
    {name = "GHOpenDebugBuffer", callback = debug.open_debug_buffer, opts = {}},
}

function M.command_select()
    vim.ui.select(
        commands,
        {
            prompt = "Select a GH command: ",
            format_item = function(cmd)
                return cmd.name
            end
        }, function(cmd)
            if cmd == nil then
                return
            end
            cmd.callback()
        end
    )
end

function M.setup()
    -- register all commands
    for _, cmd in ipairs(commands) do
        vim.api.nvim_create_user_command(cmd.name, cmd.callback, cmd.opts)
    end
    vim.api.nvim_create_user_command("GH", M.command_select, {})
end

return M
