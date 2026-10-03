import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

// Verify against the app's existing public key, not the supplied CI private key.
guard CommandLine.arguments.count == 5 else { fatalError("Expected Info.plist, ZIP, appcast, version") }
let args = CommandLine.arguments
let plistData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
guard let publicKey = Data(base64Encoded: plist["SUPublicEDKey"] as! String), publicKey.count == 32 else {
    fatalError("Invalid embedded public key")
}
let document = try XMLDocument(contentsOf: URL(fileURLWithPath: args[3]))
let items = try document.nodes(forXPath: "/rss/channel/item")
let matching = items.compactMap { $0 as? XMLElement }.filter { item in
    item.elements(forLocalName: "shortVersionString", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle").first?.stringValue == args[4]
}
guard matching.count == 1, let enclosure = matching[0].elements(forName: "enclosure").first,
      let raw = enclosure.attribute(forLocalName: "edSignature", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle")?.stringValue,
      let signature = Data(base64Encoded: raw), signature.count == 64 else {
    fatalError("Expected one signed release enclosure")
}
let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
guard key.isValidSignature(signature, for: archive) else { fatalError("Sparkle signature does not match embedded public key") }
print("Sparkle archive signature verified with embedded public key")
