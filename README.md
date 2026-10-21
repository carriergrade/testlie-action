# Testlie GitHub Action

Disposable email inboxes for CI: create an inbox, point the app under test at its SMTP
credentials, wait for the email a test expects, and use its one-time code or magic link in the
next step. A composite action in bash, `curl` and `jq` (all on GitHub-hosted runners).

## 30-second quick start

1. Sign up at [testlie.com](https://testlie.com) (free plan), create a key on the **API keys**
   page and save it as the repository secret `TESTLIE_API_KEY`.
2. Add a step:

```yaml
- id: inbox
  uses: carriergrade/testlie-action@v1
  with:
    mode: create-inbox
    api-key: ${{ secrets.TESTLIE_API_KEY }}
    disposable-minutes: 30
```

3. Point your app's SMTP settings at `steps.inbox.outputs.smtp-*`, then wait for the email with
   `mode: wait` and use `steps.<id>.outputs.otp` or `.link`. The full workflow is below.

| Mode | Inputs | Outputs |
|---|---|---|
| `create-inbox` | `name`, `disposable-minutes` (default 60, `0` keeps the inbox), `address-tag` | `inbox-id`, `smtp-host`, `smtp-port`, `smtp-username`, `smtp-password` (masked), `address`, `since`, `expires-at` |
| `wait` | `inbox-id`, `to`, `subject`, `since`, `timeout` (seconds, default 60), `link-pattern` | `message-id`, `subject`, `from`, `otp`, `link`, `extract` (JSON); **fails on timeout** |
| `delete-inbox` | `inbox-id` | |

Every mode takes `api-key` (required, from a secret) and `base-url` (default
`https://testlie.com`; set it for a self-hosted server). The API key and SMTP password are masked
with `::add-mask::`. Create and delete need a write key; a read-only key can wait.

## Example

```yaml
name: e2e
on: [push]

jobs:
  signup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Create a disposable inbox
        id: inbox
        uses: carriergrade/testlie-action@v1
        with:
          mode: create-inbox
          api-key: ${{ secrets.TESTLIE_API_KEY }}
          disposable-minutes: 30
          address-tag: signup-${{ github.run_id }}

      - name: Start the app with its SMTP settings pointed at the inbox
        run: npm ci && npm run start:test &
        env:
          SMTP_HOST: ${{ steps.inbox.outputs.smtp-host }}
          SMTP_PORT: ${{ steps.inbox.outputs.smtp-port }}
          SMTP_USER: ${{ steps.inbox.outputs.smtp-username }}
          SMTP_PASS: ${{ steps.inbox.outputs.smtp-password }}

      - name: Sign up (the app sends a verification email)
        run: npx playwright test signup --grep "submits the form"
        env:
          SIGNUP_EMAIL: ${{ steps.inbox.outputs.address }}

      - name: Wait for the verification email
        id: email
        uses: carriergrade/testlie-action@v1
        with:
          mode: wait
          api-key: ${{ secrets.TESTLIE_API_KEY }}
          inbox-id: ${{ steps.inbox.outputs.inbox-id }}
          to: ${{ steps.inbox.outputs.address }}
          subject: Verify
          since: ${{ steps.inbox.outputs.since }}
          timeout: 90
          link-pattern: /verify

      - name: Finish sign-up with the code and the link
        run: |
          echo "Got \"${{ steps.email.outputs.subject }}\""
          npx playwright test signup --grep "enters the code"
        env:
          SIGNUP_CODE: ${{ steps.email.outputs.otp }}
          VERIFY_LINK: ${{ steps.email.outputs.link }}

      - name: Delete the inbox
        if: always() && steps.inbox.outputs.inbox-id
        uses: carriergrade/testlie-action@v1
        with:
          mode: delete-inbox
          api-key: ${{ secrets.TESTLIE_API_KEY }}
          inbox-id: ${{ steps.inbox.outputs.inbox-id }}
```

The `address` output is `<alias>+<tag>@<inbound domain>` when the server has an inbound domain,
so it also works for apps that deliver through a real mail server. Without an inbound domain,
only mail sent with the inbox's SMTP credentials reaches it, and any recipient works.

Disposable inboxes are deleted by the server after `disposable-minutes` even if the delete step
never runs (a cancelled workflow, say).

## Running locally

```bash
INPUT_MODE=create-inbox INPUT_API_KEY=tl_... INPUT_BASE_URL=http://localhost:3000 bash testlie.sh
```

Outputs are printed as `name<<delimiter` blocks when `GITHUB_OUTPUT` is not set.

## Links

- Documentation: https://testlie.com/docs/sdks#github-actions
- Issues: https://github.com/carriergrade/testlie-action/issues
- Changelog: [CHANGELOG.md](CHANGELOG.md)

MIT licensed. Copyright (c) 2026 Carrier Grade Inc.
