//
//  ContentView.swift
//  CopyNFC
//
//  Created by Kamaal M Farah on 02/11/2022.
//

import SwiftUI
import CoreNFC

// [4, 21, 95, 42, 92, 103, 128] converted to Tag UID: 041505f02a05c6780

struct ContentView: View {
    @StateObject private var nfcReader = NFCReader()

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Actions")) {
                    Button(action: { nfcReader.scan() }) {
                        Text("Scan")
                            .font(.title)
                    }
                }
                
                Section(header: Text("Tags")) {
                    ForEach(nfcReader.nfcTags) { tag in
                        Button(action: { onTagPress(tag) }) {
                            Text(tag.id.uuidString)
                        }
                    }
                }
            }
            .navigationTitle(Text("Copy NFC"))
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func onTagPress(_ tag: SavedNFC) {
        print("tag", tag)
    }
}

class NFCReader: NSObject, NFCTagReaderSessionDelegate, ObservableObject {
    @Published private(set) var nfcTags: [SavedNFC] {
        didSet { UserDefaults.savedNFCs = nfcTags }
    }

    var tagSession: NFCTagReaderSession?

    override init() {
        self.nfcTags = UserDefaults.savedNFCs ?? []
    }

    func scan() {
        tagSession = NFCTagReaderSession(pollingOption: .iso14443, delegate: self)
        tagSession!.begin()
    }

    // MARK: delegate methods

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        print(session)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print(error.localizedDescription)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        for tag in tags {
            session.connect(to: tag) { [weak self] maybeError in
                if let error = maybeError {
                    print("error", error)
                    return
                }

                self?.copyData(tag)
            }
        }
    }

    // - MARK: Privates

    private func copyData(_ tag: NFCTag) {
        if case let .miFare(tag) = tag {
            let apdu = NFCISO7816APDU(
                instructionClass: 0,
                instructionCode: 0xB0,
                p1Parameter: 0,
                p2Parameter: 0,
                data: Data(),
                expectedResponseLength: 16)

            tag.sendMiFareISO7816Command(apdu) { [weak self] apduData, sw1, sw2, maybeError in
                guard let self else { return }

                if let error = maybeError {
                    print("error", error)
                    return
                }

                let nfcToSave = SavedNFC(
                    historicalBytes: tag.historicalBytes,
                    apduData: apduData,
                    identifier: tag.identifier,
                    sw1: sw1,
                    sw2: sw2)

                Task {
                    await self.setNFCTags(self.nfcTags + [nfcToSave])
                }
            }
        }
    }

    @MainActor
    private func setNFCTags(_ nfcTags: [SavedNFC]) {
        self.nfcTags = nfcTags
    }
}

struct SavedNFC: Codable, Hashable, Identifiable {
    let id: UUID
    let historicalBytes: Data?
    let apduData: Data
    let identifier: Data
    let sw1: UInt8
    let sw2: UInt8

    init(id: UUID = UUID(), historicalBytes: Data?, apduData: Data, identifier: Data, sw1: UInt8, sw2: UInt8) {
        self.id = id
        self.historicalBytes = historicalBytes
        self.apduData = apduData
        self.identifier = identifier
        self.sw1 = sw1
        self.sw2 = sw2
    }
}

extension UserDefaults {
    @UserDefaultObject(key: .savedNFCs)
    static var savedNFCs: [SavedNFC]?
}

@propertyWrapper
struct UserDefaultObject<Value: Codable> {
    let key: Keys
    let container: UserDefaults?

    init(key: Keys, container: UserDefaults? = .standard) {
        self.key = key
        self.container = container
    }

    enum Keys: String {
        case savedNFCs
    }

    var wrappedValue: Value? {
        get {
            guard let container = container else { return nil }

            let data: Data?
            if container != .standard,
               let standardValue = UserDefaults.standard.object(forKey: constructedKey) as? Data {
                container.setValue(standardValue, forKey: constructedKey)
                UserDefaults.standard.removeObject(forKey: constructedKey)

                data = standardValue
            } else {
                data = container.object(forKey: constructedKey) as? Data
            }

            guard let data = data else { return nil }

            return try? JSONDecoder().decode(Value.self, from: data)
        }
        set {
            guard let container = container else { return }

            if container != .standard, UserDefaults.standard.object(forKey: constructedKey) as? Data != nil {
                UserDefaults.standard.removeObject(forKey: constructedKey)
            }

            guard let data = try? JSONEncoder().encode(newValue) else { return }

            container.set(data, forKey: constructedKey)
        }
    }

    var projectedValue: UserDefaultObject { self }

    func removeValue() {
        container?.removeObject(forKey: constructedKey)
    }

    private var constructedKey: String {
        "\(Bundle.main.bundleIdentifier!).UserDefaults.\(key.rawValue)"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
