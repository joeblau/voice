import Foundation
import SwiftData

extension SchemaV2 {
    /// The enrolled user's voiceprint.
    ///
    /// Synced through CloudKit with the rest of the user's data, so enrolling
    /// once works on every device (product decision 2 in issue #1). The vector
    /// attributes use `.allowsCloudEncryption`, which stores them in CloudKit's
    /// end-to-end encrypted fields. That choice can't be changed once the
    /// schema is in production.
    ///
    /// Deleting a profile deletes its enrollment sets.
    @Model
    public final class VoiceProfile {
        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        /// A display name, for example "Me".
        public var name: String = ""

        /// Identifies the embedding model that produced `centroid`, for
        /// example `"wespeaker-resnet34-lm-v1"`. Vectors from different models
        /// are not comparable, so a mismatch means re-enrollment.
        public var embeddingModelVersion: String = ""

        /// The mean enrollment embedding, packed with `PackedFloat32`.
        @Attribute(.allowsCloudEncryption)
        public var centroid: Data = Data()

        public var createdAt: Date = Date.distantPast

        public var updatedAt: Date = Date.distantPast

        /// Enrollment clips' embeddings, one set per enrolling device.
        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.VoiceEnrollmentSet.profile)
        public var enrollmentSets: [SchemaV2.VoiceEnrollmentSet]? = []

        public init(
            id: UUID = UUID(),
            name: String,
            embeddingModelVersion: String,
            centroid: [Float],
            createdAt: Date,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.embeddingModelVersion = embeddingModelVersion
            self.centroid = PackedFloat32.pack(centroid)
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }

        /// The unpacked centroid, or `nil` if the stored bytes are malformed.
        public var centroidVector: [Float]? { PackedFloat32.unpack(centroid) }

        /// Replaces the centroid and stamps `updatedAt`.
        public func updateCentroid(_ vector: [Float], at date: Date) {
            centroid = PackedFloat32.pack(vector)
            updatedAt = date
        }
    }

    /// The embeddings of one enrollment session's clips, recorded on one
    /// device.
    @Model
    public final class VoiceEnrollmentSet {
        /// The WeSpeaker ResNet34-LM embedding width.
        public static let defaultDimension = 256

        public var profile: SchemaV2.VoiceProfile?

        /// The recording device's model identifier, for example
        /// `"iPhone18,1"`. Microphones differ, so per-device sets let the gate
        /// prefer local enrollment.
        public var deviceModel: String = ""

        /// `clipCount` embeddings back to back, packed with `PackedFloat32`
        /// (Float32 × 256 each for WeSpeaker).
        @Attribute(.allowsCloudEncryption)
        public var embeddings: Data = Data()

        /// How many clip embeddings `embeddings` holds.
        public var clipCount: Int = 0

        public var createdAt: Date = Date.distantPast

        /// Stores `embeddings` (one vector per clip; all the same length).
        public init(
            profile: SchemaV2.VoiceProfile? = nil,
            deviceModel: String,
            embeddings: [[Float]],
            createdAt: Date
        ) {
            self.profile = profile
            self.deviceModel = deviceModel
            self.embeddings = PackedFloat32.pack(rows: embeddings)
            self.clipCount = embeddings.count
            self.createdAt = createdAt
        }

        /// The unpacked clip embeddings, or `nil` if the stored bytes don't
        /// hold `clipCount` equal-length vectors.
        public var embeddingVectors: [[Float]]? {
            guard clipCount > 0 else { return embeddings.isEmpty ? [] : nil }
            let valueCount = embeddings.count / PackedFloat32.byteWidth
            guard valueCount.isMultiple(of: clipCount), valueCount > 0 else { return nil }
            return PackedFloat32.unpack(embeddings, dimension: valueCount / clipCount)
        }
    }
}
