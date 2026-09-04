import UIKit
import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var templateManager: CarPlayTemplateManager?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            self.templateManager = CarPlayTemplateManager()
            self.templateManager?.connect(interfaceController)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            self.templateManager?.disconnect()
            self.templateManager = nil
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didInvalidate interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            self.templateManager?.disconnect()
            self.templateManager = nil
        }
    }
}
