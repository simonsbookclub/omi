import Contacts
import Flutter
import Foundation

/// SIMONSBOOKCLUB: read-only bridge to the iOS Contacts store so identified
/// speakers can wear their real contact photo in transcripts.
///
/// Privacy shape, deliberate: contact data never leaves the phone. The app
/// stores only a mapping of person name -> contact identifier locally, and
/// re-reads the photo from Contacts on demand. Nothing here writes to the
/// address book, and nothing is uploaded to the backend.
class ContactsService {
    private let store = CNContactStore()

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasAccess":
            result(CNContactStore.authorizationStatus(for: .contacts) == .authorized)
        case "requestAccess":
            store.requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async { result(granted) }
            }
        case "listContacts":
            listContacts(result: result)
        case "getThumbnail":
            let args = call.arguments as? [String: Any]
            getThumbnail(identifier: args?["identifier"] as? String, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Every contact with a usable name, newest-Contacts-order, plus whether
    /// it carries an image. Thumbnails are fetched separately and lazily —
    /// loading a few hundred images up front would stall the picker.
    private func listContacts(result: @escaping FlutterResult) {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            result([])
            return
        }
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var contacts: [[String: Any]] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                var name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                if name.isEmpty { name = contact.nickname }
                if name.isEmpty { name = contact.organizationName }
                guard !name.isEmpty else { return }
                contacts.append([
                    "identifier": contact.identifier,
                    "name": name,
                    "hasImage": contact.imageDataAvailable,
                ])
            }
        } catch {
            print("ContactsService: enumerate failed \(error.localizedDescription)")
            result([])
            return
        }
        result(contacts)
    }

    /// Base64 thumbnail for one contact, or nil when it has no photo.
    private func getThumbnail(identifier: String?, result: @escaping FlutterResult) {
        guard let identifier = identifier,
              CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            result(nil)
            return
        }
        let keys: [CNKeyDescriptor] = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        do {
            let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
            guard let data = contact.thumbnailImageData else {
                result(nil)
                return
            }
            result(data.base64EncodedString())
        } catch {
            // Contact deleted or key unavailable — a missing photo is not an
            // error worth surfacing; the caller falls back to its avatar.
            result(nil)
        }
    }
}
