package podman

import (
	"os/exec"

	"github.com/adrianriobo/goax/pkg/util/delay"
	"github.com/containers/podman-desktop-e2e/test/extended/podman-desktop/util/ax"
)

const (
	installerBundleID    = "com.apple.installer"
	installerPodmanTitle = "Install Podman"

	installerContinue  = "Continue"
	installerAgree     = "Agree"
	installerAllow     = "Allow"
	installerInstall   = "Install"
	installerClose     = "Close"

	installerSelectLocationTitle = "Select a Destination"
)

func cleanupSystem() error {
	cmd := exec.Command("/bin/sh", "-c", "rm -rf ${HOME}/.config/containers")
	err := cmd.Start()
	if err != nil {
		return err
	}
	cmd = exec.Command("/bin/sh", "-c", "rm -rf ${HOME}/.local/share/containers")
	err = cmd.Start()
	if err != nil {
		return err
	}
	cmd = exec.Command("sudo", "rm", "-rf", "/opt/podman")
	return cmd.Start()
}

func runInstaller(userPassword string) error {
	delay.Delay(delay.XLONG)
	i, err := ax.GetAppByTypeAndTitle(installerBundleID, installerPodmanTitle)
	if err != nil {
		return installerError(err)
	}
	if err := i.Click(installerContinue, delay.SMALL); err != nil {
		return installerError(err)
	}
	if err := i.Click(installerContinue, delay.SMALL); err != nil {
		return installerError(err)
	}
	if err := i.Click(installerAgree, delay.SMALL); err != nil {
		return installerError(err)
	}
	// get foreground App (Just a system dialog, contains buttons Allow and Don't Allow)
	y, err := ax.GetForefront()
	if err := y.Click(installerAllow, delay.SMALL); err != nil {
		return installerError(err)
	}
	// reinitilize installer app
	// i, err := ax.GetAppByTypeAndTitle(installerBundleID, installerPodmanTitle) - compilation error
	if selectLocationExists, err := i.ExistsWithType(installerSelectLocationTitle, "text"); selectLocationExists {
		if err != nil {
			return installerError(err)
		}
		if err := i.Click(installerContinue, delay.SMALL); err != nil {
			return installerError(err)
		}
	}
	if err := i.Click(installerInstall, delay.SMALL); err != nil {
		return installerError(err)
	}
	if err := i.SetValueOnFocus(userPassword, delay.XLONG); err != nil {
		return installerError(err)
	}
	if err := i.Click(installerClose, delay.SMALL); err != nil {
		return installerError(err)
	}
	return nil
}
