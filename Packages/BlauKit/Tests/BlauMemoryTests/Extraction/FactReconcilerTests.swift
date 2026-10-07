import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Fact extraction: add-only, validity-dated reconciliation")
struct FactReconcilerTests {
    typealias Support = ExtractionTestSupport

    private let acme = KnownEntity(id: UUID(), name: "Acme", type: .organization, createdAt: Support.t0)
    private let lines: [NumberedUtterance] = [
        NumberedUtterance(number: 1, utterance: Support.utterance("I left Stripe and joined Acme.", at: 3_600)),
        NumberedUtterance(
            number: 2, utterance: Support.utterance("Congrats! What do they do?", speaker: .agent, at: 3_610)),
        NumberedUtterance(number: 3, utterance: Support.utterance("Acme makes anvils.", at: 3_620)),
    ]

    private func prompt(facts: [KnownFact]) -> FactExtractionPrompt {
        FactExtractionPrompt(
            date: Support.t0, topicTitle: nil, entities: [acme], facts: facts, utterances: lines,
            timeZone: Support.utc)
    }

    private func resolution(_ extraction: FactExtraction) async -> EntityResolution {
        await EntityResolver(embedder: { nil }).resolve(extraction, known: [acme])
    }

    private func userFact(
        _ predicate: String, _ object: String, from validFrom: Date = Support.t0, origin: FactOrigin = .extracted
    ) -> KnownFact {
        KnownFact(
            id: UUID(), subjectID: nil, predicate: predicate, objectText: object, validFrom: validFrom, origin: origin)
    }

    @Test func aContradictingFactInvalidatesTheOldOneAtItsSourceTime() async {
        let stripe = userFact("works at", "Stripe")
        let extraction = FactExtraction(facts: [
            .init(subject: nil, predicate: "works at", object: "Acme", confidence: 0.9, source: 1, replaces: ["f1"]),
            .init(subject: "Acme", predicate: "makes", object: "anvils", confidence: 0.8, source: 3),
        ])
        let result = FactReconciler().reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: [stripe]),
            knownFacts: [stripe], recordedAt: Support.t0.addingTimeInterval(7_200))

        #expect(result.plan.invalidations == [.init(factID: stripe.id, date: lines[0].utterance.startedAt)])
        #expect(result.plan.newFacts.count == 2)
        let joined = result.plan.newFacts[0]
        #expect(joined.subjectID == nil)
        #expect(joined.objectText == "Acme")
        #expect(joined.validFrom == lines[0].utterance.startedAt)
        #expect(joined.sourceUtteranceID == lines[0].utterance.id)
        #expect(joined.invalidatedAt == nil)
        #expect(result.plan.newFacts[1].subjectID == acme.id)
        #expect(result.plan.newFacts[1].sourceUtteranceID == lines[2].utterance.id)
        #expect(result.skipped.isEmpty)
    }

    @Test func aReplacementOnlyAppliesToTheSameSubject() async {
        let stripe = userFact("works at", "Stripe")
        let extraction = FactExtraction(facts: [
            .init(subject: "Acme", predicate: "makes", object: "anvils", source: 3, replaces: ["F1"])
        ])
        let result = FactReconciler().reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: [stripe]),
            knownFacts: [stripe], recordedAt: Support.t0)
        #expect(result.plan.invalidations.isEmpty)
        #expect(result.plan.newFacts.count == 1)
    }

    @Test func theUsersOwnFactOutranksAnExtractedContradiction() async {
        let confirmed = userFact("works at", "Stripe", origin: .user)
        let extraction = FactExtraction(facts: [
            .init(subject: nil, predicate: "works at", object: "Acme", source: 1, replaces: ["F1"])
        ])
        let result = FactReconciler().reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: [confirmed]),
            knownFacts: [confirmed], recordedAt: Support.t0)
        #expect(result.plan.invalidations.isEmpty)
        #expect(result.plan.newFacts.isEmpty)
        #expect(result.skipped == [.outrankedByUserFact: 1])
    }

    @Test func anOlderStatementIsRecordedAsAlreadySuperseded() async {
        // The known fact is newer than the conversation being extracted.
        let newer = userFact("lives in", "Berlin", from: Support.t0.addingTimeInterval(86_400))
        let extraction = FactExtraction(facts: [
            .init(subject: nil, predicate: "lives in", object: "Paris", source: 1, replaces: ["F1"])
        ])
        let result = FactReconciler().reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: [newer]),
            knownFacts: [newer], recordedAt: Support.t0)
        #expect(result.plan.invalidations.isEmpty)
        #expect(result.plan.newFacts.first?.invalidatedAt == newer.validFrom)
        #expect(result.plan.newFacts.first?.validFrom == lines[0].utterance.startedAt)
    }

    @Test func repeatsAndLowConfidenceFactsAreDropped() async {
        let known = userFact("works at", "Acme")
        let extraction = FactExtraction(facts: [
            .init(subject: "user", predicate: "Works  at", object: "acme.", source: 1),
            .init(subject: nil, predicate: "likes", object: "anvils", confidence: 0.2),
            .init(subject: nil, predicate: "likes", object: "espresso", source: 3),
            .init(subject: nil, predicate: "likes", object: "Espresso", source: 3),
        ])
        let result = FactReconciler(minimumConfidence: 0.5).reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: [known]),
            knownFacts: [known], recordedAt: Support.t0)
        #expect(result.plan.newFacts.map(\.objectText) == ["espresso"])
        #expect(result.skipped == [.duplicate: 2, .lowConfidence: 1])
    }

    @Test func aFactWithoutAUsableSourceIsValidFromTheWindowStart() async {
        let extraction = FactExtraction(facts: [
            .init(subject: nil, predicate: "prefers", object: "short answers", source: 99)
        ])
        let result = FactReconciler().reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: []), knownFacts: [],
            recordedAt: Support.t0)
        #expect(result.plan.newFacts.first?.validFrom == lines[0].utterance.startedAt)
        #expect(result.plan.newFacts.first?.sourceUtteranceID == nil)
    }

    @Test func unknownHandlesAreIgnored() async {
        let stripe = userFact("works at", "Stripe")
        let extraction = FactExtraction(facts: [
            .init(subject: nil, predicate: "works at", object: "Acme", source: 1, replaces: ["F7", "garbage"])
        ])
        let result = FactReconciler().reconcile(
            extraction, resolution: await resolution(extraction), prompt: prompt(facts: [stripe]),
            knownFacts: [stripe], recordedAt: Support.t0)
        #expect(result.plan.invalidations.isEmpty)
        #expect(result.plan.newFacts.count == 1)
    }
}
