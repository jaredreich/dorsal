import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject var jellyfinService: JellyfinService
    @EnvironmentObject var albumCoordinator: AlbumStateCoordinator
    @State private var serverUrl: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: LocalizedStringKey?
    @FocusState private var focusedField: Field?

    enum Field {
        case serverUrl
        case username
        case password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image("AppLogoTransparent")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)

                    Text("general.app_name")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                }
                .padding(.top, 80)
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text("setup.server_url.label")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    TextField("setup.server_url.label", text: $serverUrl, prompt: Text("setup.server_url.placeholder").foregroundColor(Color(uiColor: .placeholderText)))
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .disabled(isLoggingIn)
                        .focused($focusedField, equals: .serverUrl)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .username
                        }
                }
                .padding(.horizontal, 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text("setup.username.label")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    TextField("setup.username.label", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .disabled(isLoggingIn)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .password
                        }
                }
                .padding(.horizontal, 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text("setup.password.label")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    SecureField("setup.password.label", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .disabled(isLoggingIn)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit {
                            login()
                        }
                }
                .padding(.horizontal, 40)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Button(action: login) {
                    HStack {
                        if isLoggingIn {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("setup.sign_in.button")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(serverUrl.isEmpty || username.isEmpty ? Color.gray : Color.appAccent)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(serverUrl.isEmpty || username.isEmpty || isLoggingIn)
                .padding(.horizontal, 40)
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            if let savedUrl = jellyfinService.authState.serverUrl {
                serverUrl = savedUrl
            }
        }
    }

    private func login() {
        let urlToValidate = serverUrl.trimmingCharacters(in: .whitespaces)

        guard URL(string: urlToValidate) != nil else {
            errorMessage = "setup.error.invalid_url"
            return
        }

        isLoggingIn = true
        errorMessage = nil

        Task {
            do {
                try await jellyfinService.authenticate(
                    serverUrl: urlToValidate,
                    username: username,
                    password: password
                )

                Task.detached {
                    do {
                        try await AlbumStateCoordinator.shared.fetchAlbums()

                        await MainActor.run {
                            UserDefaults.standard.set(Date(), forKey: "lastSyncDate")
                        }
                    } catch {
                        // TODO: handle this (sync failed but authentication succeeded, user can manually sync later from settings)
                    }
                }

                await MainActor.run {
                    isLoggingIn = false
                }
            } catch {
                await MainActor.run {
                    isLoggingIn = false
                    errorMessage = "setup.error.invalid_credentials"
                }
            }
        }
    }
}
