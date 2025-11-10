package podmandesktop

import (
	"fmt"

	autoApp "github.com/adrianriobo/goax/pkg/goax/app"
	"github.com/adrianriobo/goax/pkg/util/delay"
	"github.com/adrianriobo/goax/pkg/util/logging"
	"github.com/adrianriobo/goax/pkg/util/screenshot"
	. "github.com/onsi/gomega"

	"github.com/containers/podman-desktop-e2e/test/context"
	podmanExtension "github.com/containers/podman-desktop-e2e/test/extended/podman-desktop/extension/podman"
	"github.com/containers/podman-desktop-e2e/test/extended/podman-desktop/util/ax"
)

type PDApp struct {
	*ax.AXApp
}

func CleanupSystem() error {
	if err := cleanup(); err != nil {
		logging.Errorf("error cleaning up system from podman: %v", err)
		return err
	}
	if err := podmanExtension.CleanupSystem(); err != nil {
		logging.Errorf("error cleaning up system from podman extension: %v", err)
		return err
	}
	return nil
}

func Open(execPath string) (*PDApp, error) {
	if err := autoApp.Open(execPath); err != nil {
		return nil, fmt.Errorf("error opening the podman desktop executable at %s: %v", execPath, err)
	}
	// We open remotely so we wait for a bit
	delay.Delay(delay.XLONG)
	if context.SaveScreenshots() {
		if err := screenshot.CaptureScreen(context.TestContext.ScreenshotsOutputPath, "openApp"); err != nil {
			logging.Errorf("error capturing the screenshot: %v", err)
		}
	}
	a, err := ax.GetForefront()
	if err != nil {
		return nil, fmt.Errorf("error opening the podman desktop executable at %s: %v", execPath, err)
	}
	return &PDApp{a}, nil
}

// On Welcome page we should have telemetry as enable by default
// we change to disable and go to podman
func (p *PDApp) WelcomePageDisableTelemetry() error {
	
	Eventually(func() error {
		// If it fails (element not found, etc.), it returns an error,
		// and Eventually will try again.
		return p.ClickWithType(welcomePageEnableTelemetry, "checkbox", delay.LONG)
	}, "30s", "500ms").Should(Succeed(), "Failed to click the telemetry checkbox")
	
	return nil
}

func (p *PDApp) WelcomePageGoToPodman() error {
	if err := p.Click(welcomePageGoToPodmanDesktop, delay.SMALL); err != nil {
		return fmt.Errorf("error going to welcome page: %v", err)
	}
	return nil
}

func (p *PDApp) Close() error {
	if err := p.Click(appClose, delay.SMALL); err != nil {
		return fmt.Errorf("error closing the app: %v", err)
	}
	return nil
}
