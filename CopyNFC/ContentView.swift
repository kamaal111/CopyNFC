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

    @State private var showDetailSheet = false
    @State private var selectedTag: SavedNFC?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Actions")) {
                    Button(action: { nfcReader.scanTag() }) {
                        Text("Scan tag")
                    }
                    Button(action: { nfcReader.scanReader() }) {
                        Text("Scan reader")
                    }
                }
                
                Section(header: Text("Tags")) {
                    if nfcReader.nfcTags.isEmpty {
                        Text("No tags saved yet")
                    }
                    ForEach(nfcReader.nfcTags) { tag in
                        Button(action: { onTagPress(tag) }) {
                            Text(tag.id.uuidString)
                        }
                    }
                }
            }
            .navigationTitle(Text("Copy NFC"))
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: selectedTag, perform: { newValue in showDetailSheet = newValue != nil })
            .sheet(isPresented: $showDetailSheet) {
                Button(action: {
                    guard let selectedTag else {
                        showDetailSheet = false
                        return
                    }

                    nfcReader.writeDataToTag(selectedTag)
                }) {
                    Text("Write")
                }
            }
        }
    }

    private func onTagPress(_ tag: SavedNFC) {
        selectedTag = tag
    }
}

class NFCReader: NSObject, ObservableObject, NFCTagReaderSessionDelegate, NFCNDEFReaderSessionDelegate {
    @Published private(set) var nfcTags: [SavedNFC] {
        didSet { UserDefaults.savedNFCs = nfcTags }
    }

    private var tagSession: NFCTagReaderSession?
    private var readSession: NFCNDEFReaderSession?

    override init() {
        self.nfcTags = UserDefaults.savedNFCs ?? []

        super.init()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.scanTag()
        }
    }

    func scanTag() {
        tagSession = NFCTagReaderSession(pollingOption: .iso14443, delegate: self)
        tagSession!.begin()
    }

    func scanReader() {
        readSession = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
        readSession!.begin()
    }

    func writeDataToTag(_ tag: SavedNFC) {
        print("tag", tag)

        let tagUIDData = tag.identifier
        var byteData: [UInt8] = []
        tagUIDData.withUnsafeBytes { byteData.append(contentsOf: $0) }

        var uidString = ""
        for byte in byteData {
            let decimalNumber = String(byte, radix: 16)
            if (Int(decimalNumber) ?? 0) < 10 { // add leading zero
                uidString.append("0\(decimalNumber)")
            } else {
                uidString.append(decimalNumber)
            }
        }
        print("uidString", uidString)

        // These properties prepare a T2T write command to write a 4 byte block at a specific block offset.
        let writeBlockCommand: UInt8 = 0xA2
        let successCode: UInt8 = 0x0A
        let blockSize = 4
        var blockData: Data = tag.identifier.prefix(blockSize)

        // You need to zero-pad the data to fill the block size.
        if blockData.count < blockSize {
            blockData += Data(count: blockSize - blockData.count)
        }

        let writeCommand = Data([writeBlockCommand, 4]) + blockData
        print("writeCommand", writeCommand)
    }

    // MARK: NFCNDEFReaderSessionDelegate

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        print(error.localizedDescription)
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        for message in messages {
            for record in message.records {
                print("record", record)
            }
        }
    }

    // MARK: NFCTagReaderSessionDelegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        print(session)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print(error.localizedDescription)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        print("tags", tags)
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
        print("tag", tag)

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

                    self.tagSession?.invalidate()
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
