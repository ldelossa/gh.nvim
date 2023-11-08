local M = {}

-- gh: Type mismatch on variable $pull and argument pullRequestId (String! / ID)
-- Type mismatch on variable $review and argument pullRequestReviewId (String! / ID)
-- Type mismatch on variable $commit and argument commitOID (String! / GitObjectID)
-- Type mismatch on variable $reply and argument inReplyTo (String! / ID)
M.reply_comment_review = [[
mutation ($pull: ID!, $review: ID!, $commit: GitObjectID!, $body: String!, $reply: ID!) {
  addPullRequestReviewComment(
    input: {pullRequestId: $pull, pullRequestReviewId: $review, commitOID: $commit, body: $body, inReplyTo: $reply}
  ) {
    clientMutationId
  }
}
]]

M.create_comment_review = [[
mutation ($pull: ID!, $review: ID!, $body: String!, $path: String!, $line: Int!, $side: DiffSide!) {
  addPullRequestReviewThread(
    input: {pullRequestId: $pull, pullRequestReviewId: $review, body: $body, path: $path, line: $line, side: $side}
  ) {
    clientMutationId
  }
}
]]

M.create_comment_review_multiline = [[
mutation ($pull: ID!, $review: ID!, $body: String!, $path: String!, $start_line: Int!, $line: Int!, $side: DiffSide!) {
  addPullRequestReviewThread(
    input: {pullRequestId: $pull, pullRequestReviewId: $review, body: $body, path: $path, startLine: $start_line, line: $line, startSide: $side, side: $side}
  ) {
    clientMutationId
  }
}
]]

M.resolve_thread = [[
mutation ($thread_id: ID!) {
  resolveReviewThread(input: {threadId: $thread_id}) {
    clientMutationId
  }
}
]]

M.unresolve_thread = [[
mutation ($thread_id: ID!) {
  unresolveReviewThread(input: {threadId: $thread_id}) {
    clientMutationId
  }
}
]]

M.add_reaction = [[
mutation ($id: ID!, $content: ReactionContent!) {
  addReaction(input: {subjectId: $id, content: $content}) {
    clientMutationId
  }
}
]]

M.remove_reaction = [[
mutation ($id: ID!, $content: ReactionContent!) {
  removeReaction(input: {subjectId: $id, content: $content}) {
    clientMutationId
  }
}
]]

M.issue_comments_query = [[
query($name: String!, $owner: String!, $number: Int!) { 
  repository(name: $name, owner: $owner) {
    pullRequest(number: $number) {
      comments(first: 50) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            author {
              login
              
            }
            authorAssociation
            body
            createdAt
            id
            url
            reactions(first:20) {
              edges {
                node {
                  content
                  id
                  user {
                    login
                  }
                }
              }
            }
            publishedAt
            updatedAt
            url
            viewerCanReact
            viewerCanDelete
            viewerCanUpdate
            viewerDidAuthor
            viewerCanMinimize
          }
        }
      }
    }
  }
}
]]

M.issue_comments_query_cursor = [[
query($name: String!, $owner: String!, $number: Int!, $cursor: String!) { 
  repository(name: $name, owner: $owner) {
    pullRequest(number: $number) {
      comments(first: 50, after: $cursor) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            author {
              login
              
            }
            authorAssociation
            body
            createdAt
            id
            url
            reactions(first:20) {
              edges {
                node {
                  content
                  id
                  user {
                    login
                  }
                }
              }
            }
            publishedAt
            updatedAt
            url
            viewerCanReact
            viewerCanDelete
            viewerCanUpdate
            viewerDidAuthor
            viewerCanMinimize
          }
        }
      }
    }
  }
}
]]

M.review_threads_query = [[
query ($name: String!, $owner: String!, $pull_number: Int!) {
  repository(name: $name, owner: $owner) {
    pullRequest(number: $pull_number) {
      reviewThreads(first: 50) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            id
            diffSide
            isOutdated
            isResolved
            line
            originalLine
            originalStartLine
            path
            startDiffSide
            startLine
            viewerCanReply
            viewerCanResolve
            viewerCanUnresolve
            resolvedBy {
              login
            }
            comments(first: 100) {
              edges {
                node {
                  id
                  author {
                    login
                    avatarUrl
                    resourcePath
                    url
                  }
                  body
                  createdAt
                  path
                  position
                  originalPosition
                  publishedAt
                  replyTo {
                    id
                  }
                  pullRequestReview {
                    id
                  }
                  commit {
                    oid
                    parents(first: 1) {
                      edges {
                        node {
                          id
                          oid
                        }
                      }
                    }
                  }
                  originalCommit {
                    oid
                    parents(first: 1) {
                      edges {
                        node {
                          id
                          oid
                        }
                      }
                    }
                  }
                  reactions(first:20) {
                    edges {
                      node {
                        content
                        id
                        user {
                          login
                        }
                      }
                    }
                  }
                  state
                  updatedAt
                  viewerCanDelete
                  viewerCanMinimize
                  viewerCanReact
                  viewerCanUpdate
                  viewerCannotUpdateReasons
                  viewerDidAuthor
                  url
                  diffHunk
                }
              }
            }
          }
        }
      }
    }
  }
}
]]

M.review_threads_query_cursor = [[
query ($name: String!, $owner: String!, $pull_number: Int!, $cursor: String!) {
  repository(name: $name, owner: $owner) {
    pullRequest(number: $pull_number) {
      reviewThreads(first: 50, after: $cursor) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            id
            diffSide
            isOutdated
            isResolved
            line
            originalLine
            originalStartLine
            path
            startDiffSide
            startLine
            viewerCanReply
            viewerCanResolve
            viewerCanUnresolve
            resolvedBy {
              login
            }
            comments(first: 100) {
              edges {
                node {
                  id
                  author {
                    login
                    avatarUrl
                    resourcePath
                    url
                  }
                  body
                  createdAt
                  path
                  position
                  publishedAt
                  replyTo {
                    id
                  }
                  pullRequestReview {
                    id
                  }
                  commit {
                    oid
                    parents(first: 1) {
                      edges {
                        node {
                          id
                          oid
                        }
                      }
                    }
                  }
                  reactions(first:20) {
                    edges {
                      node {
                        content
                        id
                        user {
                          login
                        }
                      }
                    }
                  }
                  state
                  updatedAt
                  viewerCanDelete
                  viewerCanMinimize
                  viewerCanReact
                  viewerCanUpdate
                  viewerCannotUpdateReasons
                  viewerDidAuthor
                  url
                }
              }
            }
          }
        }
      }
    }
  }
}
]]

M.get_full_details = [[
query ($name: String!, $owner: String!, $pull_number: Int!) {
    {
      repository(name: $name, owner: $owner) {
        pullRequest(number: $pull_number) {
          additions
          assignees(first: 100) {
            edges {
              node {
                id
                login
              }
            }
          }
          author {
            login
          }
          authorAssociation
          baseRefOid
          baseRefName
          baseRepository {
            id
            name
            owner {
              id
              login
            }
          }
            headRefOid
          headRefName
          headRepository {
            id
            name
            owner {
              id
              login
            }
          }
            body
          closed
          closedAt
          closingIssuesReferences(first:100) {
            edges {
              node {
                id
                number
              }
            }
          }
          comments(first: 100) {
            edges {
              node {
                author{
                  login
                }
                body
                createdAt
                id
                isMinimized
                lastEditedAt
                minimizedReason
                publishedAt
                reactions(first: 100) {
                  edges {
                    node {
                      content
                      user {
                        login
                      }
                      id
                    }
                  }
                }
                updatedAt
                url
                viewerCanDelete
                viewerCanReact
                viewerCanUpdate
                viewerCanMinimize
                viewerDidAuthor
              }
            }
          }
          commits(first: 100) {
            edges {
              node {
                commit {
                  abbreviatedOid
                  additions
                  author {
                    user {
                      id
                      login
                    }
                  }
                  authoredByCommitter
                  authoredDate
                  changedFiles
                  commitUrl
                  committedDate
                  deletions
                  id
                  message
                  messageBody
                  oid
                  parents(first:1) {
                    edges {
                      node {
                        oid
                        abbreviatedOid
                      }
                    }
                  }
                  pushedDate
                  status {
                    id
                  }
                  url
                }
              }
            }
          }
          createdAt
          deletions
          id
          labels(first: 100) {
            edges {
              node {
                id
                color
                description
                name
              }
            }
          }
          lastEditedAt
          mergeable
          merged
          mergedAt
          number
          participants(first:100) {
            edges {
              node {
                id
              }
            }
          }
          publishedAt
          reactions(first: 100) {
            edges {
              node {
                id
                content
                user {
                  login
                }
              }
            }
          }
          reviewRequests(first:100) {
            edges {
              node {
                id
                requestedReviewer 
              }
            }
          }
          reviews(first: 100) {
            edges {
              node {
                id
                author {
                  login
                }
                body
                state
                submittedAt
                updatedAt
                url
                viewerDidAuthor
                viewerCanReact
                viewerCanDelete
                viewerCanUpdate
              }
            }
          }
          state
          title
          updatedAt
          url
          viewerDidAuthor	
          reviewThreads(first: 100) {
            edges {
              node {
                id
                comments(first:100) {
                  edges {
                    node {
                      author {
                        login
                      }
                      authorAssociation
                      body
                      commit {
                        abbreviatedOid
                        oid
                      }
                      createdAt
                      diffHunk
                      draftedAt
                      isMinimized
                      lastEditedAt
                      originalCommit {
                        id
                      }
                      originalPosition
                      outdated
                      path
                      position
                      publishedAt
                      state
                      pullRequestReview {
                        id
                      }
                      reactions(first: 10) {
                        edges {
                          node {
                            id
                            content
                            user {
                              login
                            }
                          }
                        }
                      }
                      replyTo {
                        id
                      }
                      updatedAt
                      url
                      viewerCanDelete
                      viewerCanReact
                      viewerCanUpdate
                      viewerCanMinimize
                      viewerDidAuthor
                    }
                  }
                }
                diffSide
                isCollapsed
                isOutdated
                isResolved
                line
                originalLine
                originalStartLine
                path
                resolvedBy {
                  id
                  user {
                      login
                  }
                }
                startDiffSide
                startLine
                originalStartLine
                viewerCanReply
                viewerCanResolve
                viewerCanUnresolve
              }
            }
          }
        }
      }
    }
}
]]

M.pull_files_viewed_states_query = [[
query($name: String!, $owner: String!, $pull_number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pull_number) {
      id
      files(first: 50) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            path
            viewerViewedState
          }
        }
      }
    }
  }
}
]]

M.pull_files_viewed_states_query_cursor = [[
query($name: String!, $owner: String!, $pull_number: Int!, $cursor: String!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pull_number) {
      id
      files(first: 50, after: $cursor) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            path
            viewerViewedState
          }
        }
      }
    }
  }
}
]]

M.mark_file_as_viewed = [[
mutation ($pull_request_id: ID!, $path: String!) {
	markFileAsViewed( input: {pullRequestId: $pull_request_id, path: $path}) {
	  clientMutationId
	}
}
]]

M.mark_file_as_unviewed = [[
mutation ($pull_request_id: ID!, $path: String!) {
	unmarkFileAsViewed( input: {pullRequestId: $pull_request_id, path: $path}) {
	  clientMutationId
	}
}
]]

return M
