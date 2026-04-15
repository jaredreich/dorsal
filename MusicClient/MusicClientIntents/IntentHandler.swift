//  Routes Siri intents to appropriate handlers

import Intents

class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        if intent is INPlayMediaIntent {
            return PlayMediaIntentHandler()
        }

        return self
    }
}
