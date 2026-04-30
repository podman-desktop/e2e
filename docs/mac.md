# Mac machines setup

In order to run podman-destkop-e2e on a MAC target machine there are several requirements we need to tackle:

- Setup the autologin for the user; this is required as podman-desktop-e2e uses X session from the user, as so we need to have the user already logged in, the commands required for such setup can be checked at [qenvs mac bootstrap script](https://github.com/adrianriobo/qenvs/blob/059ac80a7b6fc22879492f6b05cd6f071390f447/pkg/provider/aws/action/mac/bootstrap.sh#L13)

- Enable accessibility features, as the base to interact with UX element is the accessibility through goax library we need to enable the application to make use of accessibility, in case this is not enabled by default [it wil show a warning](https://github.com/adrianriobo/goax/pull/15)

- Authorized to send Apple events to System Events, to add the user password to allow installation of functionality for extensions (i.e podman installer) podman-desktop-e2e uses applescript to interact and send events to the system, as so we need to [authorize those events](https://ajar.freshdesk.com/support/solutions/articles/26000045119-install-error-not-authorized-to-send-apple-events-to-system-events-). Also in order to add the System Events to the automation we can run the applescript `osascript -e 'tell application "System Events"' -e 'keystroke "echo hi"' -e end`