local pr = require('litee.gh.pr')
local dv = require('litee.gh.pr.diff_view')
local pr_handlers = require('litee.gh.pr.handlers')
local issues = require('litee.gh.issues')

local M = {}

function M.setup()
    -- use a vim.ui.select prompt to open one of the first 100 pull requests.
    vim.api.nvim_create_user_command("GHOpenPR", pr.open_pull, {nargs="?"})
    -- open the Pull Request panel in the side bar panel
    vim.api.nvim_create_user_command("GHOpenToPR", pr.open_to_pr, {})
    -- open the Pull Request panel in a pop out window
    vim.api.nvim_create_user_command("GHPopOutPR", pr.popout_to_pr, {})
    -- open the Commit panel in the side bar panel.
    vim.api.nvim_create_user_command("GHOpenToCommit", pr.open_to_pr_files, {})
    -- open the Commit panel in a pop out window
    vim.api.nvim_create_user_command("GHPopOutCommit", pr.popout_to_pr_files, {})
    -- collapse the node within the Pull Request panel
    vim.api.nvim_create_user_command("GHCollapsePR", pr.collapse_pr, {})
    -- expand the node within the Pull Request panel
    vim.api.nvim_create_user_command("GHExpandPR", pr.expand_pr, {})
    -- collapse the node within the Commit panel
    vim.api.nvim_create_user_command("GHCollapseCommit", pr.collapse_pr_commits, {})
    -- expand the node within the Commit panel
    vim.api.nvim_create_user_command("GHExpandCommit", pr.expand_pr_commits, {})
    -- collapse the node within the Review panel
    vim.api.nvim_create_user_command("GHCollapseReview", pr.collapse_pr_review, {})
    -- expand the node within the Review panel
    vim.api.nvim_create_user_command("GHExpandReview", pr.expand_pr_review, {})
    -- refresh all details of the PR
    vim.api.nvim_create_user_command("GHRefreshPR", pr_handlers.on_refresh, {})
    -- refresh just comments, useful to fresh convo buffers quicker.
    vim.api.nvim_create_user_command("GHRefreshComments", pr_handlers.refresh_comments, {})
    -- refresh any open issue buffers, if a PR is opened, this will be ran as part of "GHRefreshPR"
    vim.api.nvim_create_user_command("GHRefreshIssues", issues.on_refresh, {})
    -- start a code review
    vim.api.nvim_create_user_command("GHStartReview", pr.start_review, {})
    -- submit all pending comments in a code review
    vim.api.nvim_create_user_command("GHSubmitReview", pr.submit_review, {})
    -- delete the current code review
    vim.api.nvim_create_user_command("GHDeleteReview", pr.delete_review, {})
    -- open the main Pull Request details convo buffer.
    vim.api.nvim_create_user_command("GHPRDetails", pr.open_pr_buffer, {})
    -- when cursor is on a commented line of a diff view, toggle the convo buffer.
    vim.api.nvim_create_user_command("GHToggleThreads", function() dv.toggle_threads(nil) end, {})
    -- when cursor is on a commented line of a diff view, move to the next convo buffer
    vim.api.nvim_create_user_command("GHNextThread", dv.next_thread, {})
    -- when cursor is on a line which can be commented in a diff view, create a comment
    vim.api.nvim_create_user_command("GHCreateThread", dv.create_comment, {range=true})
    -- close a PR and cleanup any state associated with it (happens on tab and neovim close as well)
    vim.api.nvim_create_user_command("GHClosePR", pr.close_pull, {})
    -- close the Commit panel
    vim.api.nvim_create_user_command("GHCloseCommit", function() pr.close_pr_commits(nil) end, {})
    -- close the Review panel
    vim.api.nvim_create_user_command("GHCloseReview", function () pr.close_pr_review(nil) end, {})
    -- preview the issue or pull request number under the cursor
    vim.api.nvim_create_user_command("GHPreviewIssue", issues.preview_issue_under_cursor, {})
    -- Add a label to the currently opened pull request.
    vim.api.nvim_create_user_command("GHAddLabel", pr.add_label, {})
    -- If possible, open the node under the cursor in your web browser.
    vim.api.nvim_create_user_command("GHViewWeb",  pr.open_node_url, {})
    -- Open an issue, if a number is provided it will be opened directly, if not
    -- a vim.ui.select with all repo issues is opened for selection.
    vim.api.nvim_create_user_command("GHOpenIssue", issues.open_issue, {nargs="?"})
end

return M
