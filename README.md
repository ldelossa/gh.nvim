             ██████╗ ██╗  ██╗   ███╗   ██╗██╗   ██╗██╗███╗   ███╗
            ██╔════╝ ██║  ██║   ████╗  ██║██║   ██║██║████╗ ████║
            ██║  ███╗███████║   ██╔██╗ ██║██║   ██║██║██╔████╔██║
            ██║   ██║██╔══██║   ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║ Powered by
            ╚██████╔╝██║  ██║██╗██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║ litee.nvim
             ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝


GH.nvim, initially, is a plugin for interactive code reviews which take place
on the GitHub platform. 

This plugin was created due to the repeat frustration of performing code reviews
of complex changes in the GitHub web UI. 

The mentioned frustration seemed to boil down to a few major drawbacks which GH.nvim
sets out to fix. These are:

1) Lack of context during code review
    When viewing a pull request in a large code base its very likely that you're
    not sure of the full context of the change. The patch may change the way a 
    function works, but you are not aware all the places this function may be 
    called. Its difficult to safely say that the patch is OK and approve it.

    To alleviate this, GH.nvim will make the pull request code locally available
    on your file system.

2) Lack of sufficient editor tools like LSP
    Because the pull request's code is made locally available all your LSP tools
    work as normal. 

    In my previous point, this means performing a LSP call to understand all the 
    usages of the editing function is now possible. 

3) Lack of automation when attempting to view the full context of a pull request.
    GH.nvim automates the process of making the pull request's code locally available.
    To do this, GH.nvim embeds a `git` CLI wrapper. 

    When a pull request is opened in GH.nvim the remote is added locally, the 
    branch is fetched, and the repo is checked out to the pull request's HEAD.

4) Inability to edit and run the code in the pull request.
    Because the pull request's code is made available locally, its completely 
    editable in your familiar `neovim` instance. 

    This works for both for writing reviews and responding to reviews of your
    pull request. 

    You can build up a diff while responding to review comments, stash them, 
    check out your branch, and rebase those changes into your PR and push again.
    Much handier then jumping back and forth between `neovim` and a browser.

    Additionally, since the code is local and checked out on your file system,
    you can now run any local development environments that may exist. The 
    environment will be running the pull request's code and you can perform sanity
    checks easily.

GH.nvim is a "commit-wise" review tool. This means you browse the changed files
by their commits. This will feel familiar to those who immediately click on the
"commits" tab on the GitHub UI to view the incremental changes of the pull request.

GH.nvim holds the opinion that this is the correct way to do a code review and 
and the TUI emphasizes this workflow.

see doc/gh-nvm.txt for usage and more details.

Checkout my [rational and demo video](https://youtu.be/hhrWwYfMK1I) to get an initial idea of how gh.nvim works, why it works the way it does, and its look and feel. 
