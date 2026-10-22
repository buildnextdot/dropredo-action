# DropRedo Browser Tests

Run your [DropRedo](https://dropredo.com) browser tests from GitHub Actions. The action starts a run, waits for the result, fails the job when a test fails, and posts the run report link on the pull request.

DropRedo runs plain-English browser tests in real Chromium, Firefox and WebKit browsers, with video, screenshots and step logs for every run.

## Quick start

1. In DropRedo, create an API token under **API Tokens**, and copy a trigger ID from the **API** tab of an application's or group's **Triggers** page.
2. In your repository, add the token as an Actions secret named `DROPREDO_API_TOKEN` (**Settings > Secrets and variables > Actions > New repository secret**).
3. Add the action to a workflow:

```yaml
- uses: buildnextdot/dropredo-action@v1
  with:
    api-token: ${{ secrets.DROPREDO_API_TOKEN }}
    trigger-id: YOUR_TRIGGER_ID
```

A complete workflow, `.github/workflows/dropredo.yml`, that runs on every pull request and comments the result on it:

```yaml
name: DropRedo

on:
  pull_request:

permissions:
  pull-requests: write # to comment the report link on the pull request

jobs:
  dropredo:
    runs-on: ubuntu-latest
    timeout-minutes: 35
    steps:
      - uses: buildnextdot/dropredo-action@v1
        with:
          api-token: ${{ secrets.DROPREDO_API_TOKEN }}
          trigger-id: YOUR_TRIGGER_ID
```

The action needs no checkout: your tests live in DropRedo.

## What it does

1. Starts a run of the trigger through `POST /api/v1/triggers/{triggerId}/run`.
2. Polls `GET /api/v1/executions/{executionId}` every 15 seconds until the run finishes.
3. Writes the result, the test counts and the report link to the job summary.
4. On a pull request, posts the same as a comment. Later runs of the same trigger and browser update that comment instead of adding new ones.
5. Fails the job when the run fails, is force-stopped, pauses for manual action, or does not finish within `timeout-minutes`.

The report link is a public page with each test's steps, result and video. It never shows step values, logs or failure messages. Set `public-report: false` to link the run in the DropRedo app instead, which needs a sign-in.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `api-token` | (required) | A DropRedo API token. Pass it from a secret. |
| `trigger-id` | (required) | The trigger to run, from the API tab of a Triggers page. |
| `browser` | `chromium` | `chromium`, `firefox` or `webkit`. Use a matrix to run several. |
| `environments` | all | Environment IDs to run against, separated by commas or new lines. |
| `wait` | `true` | Wait for the result and fail the job when the run fails. `false` only starts the run. |
| `timeout-minutes` | `30` | How long to wait before failing the job. Keep the job's own `timeout-minutes` above it. |
| `poll-interval-seconds` | `15` | How often to ask for the run's status. |
| `public-report` | `true` | Give the run a public report page to link. |
| `comment-on-pr` | `true` | Comment the result on the pull request. Needs `pull-requests: write`. |
| `github-token` | `github.token` | The token used to comment. |
| `pull-request-number` | the triggering pull request | The pull request to comment on. Empty skips the comment. |
| `github-api-url` | `github.api_url` | The GitHub API address, for GitHub Enterprise Server. |
| `api-url` | `https://app.dropredo.com` | The DropRedo app's address. |

## Outputs

| Output | Description |
| --- | --- |
| `execution-id` | The run's ID. |
| `status` | The run's last status: `running`, `waiting for manual action`, `completed`, `failed` or `force stopped`. |
| `passed` | `true` when the run finished with no failed tests, `false` otherwise. Empty when `wait` is `false`. |
| `report-url` | The public run report, or the run in the app when the report is not public. |
| `app-url` | The run in the DropRedo app. |

## Examples

### Every browser

```yaml
jobs:
  dropredo:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        browser: [chromium, firefox, webkit]
    steps:
      - uses: buildnextdot/dropredo-action@v1
        with:
          api-token: ${{ secrets.DROPREDO_API_TOKEN }}
          trigger-id: YOUR_TRIGGER_ID
          browser: ${{ matrix.browser }}
```

Each browser gets its own comment on the pull request.

### After a deploy, against one environment

```yaml
      - uses: buildnextdot/dropredo-action@v1
        with:
          api-token: ${{ secrets.DROPREDO_API_TOKEN }}
          trigger-id: YOUR_TRIGGER_ID
          environments: YOUR_STAGING_ENVIRONMENT_ID
```

### Start the run without waiting

```yaml
      - uses: buildnextdot/dropredo-action@v1
        id: dropredo
        with:
          api-token: ${{ secrets.DROPREDO_API_TOKEN }}
          trigger-id: YOUR_TRIGGER_ID
          wait: false
      - run: echo "Report at ${{ steps.dropredo.outputs.report-url }}"
```

## Notes

- **Pull requests from forks** get no repository secrets and a read-only token, so the run cannot start there. Run DropRedo on pushes, or on pull requests from branches in the repository.
- **Runners:** the action uses `bash`, `curl` and `jq`, which GitHub-hosted Linux and macOS runners have.
- **Rate limits:** a token can start 30 runs a minute and read 120 statuses a minute. Keep `poll-interval-seconds` at 15 or above when you run many browsers or jobs at once.

## License

[MIT](LICENSE)
