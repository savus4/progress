import CoreData
import Foundation

/// Value snapshots keep managed objects on their context queue during store copying.
nonisolated enum PhotoLibraryAttribute: Sendable {
    case data(Data), date(Date), uuid(UUID), string(String), number(Double), integer(Int64), boolean(Bool)

    init(value: Any, type: NSAttributeType) throws {
        switch type {
        case .binaryDataAttributeType: self = .data(value as! Data)
        case .dateAttributeType: self = .date(value as! Date)
        case .UUIDAttributeType: self = .uuid(value as! UUID)
        case .stringAttributeType: self = .string(value as! String)
        case .doubleAttributeType, .floatAttributeType: self = .number((value as! NSNumber).doubleValue)
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: self = .integer((value as! NSNumber).int64Value)
        case .booleanAttributeType: self = .boolean((value as! NSNumber).boolValue)
        default: throw CocoaError(.validationMissingMandatoryProperty)
        }
    }

    var value: Any {
        switch self {
        case .data(let value): value
        case .date(let value): value
        case .uuid(let value): value
        case .string(let value): value
        case .number(let value): value
        case .integer(let value): value
        case .boolean(let value): value
        }
    }
}
