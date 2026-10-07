import BlauCore
import BlauTopics
import Foundation
import Testing

/// A scripted conversation with hand-labelled topic boundaries.
///
/// `boundaries` holds the index of the first exchange of each new topic,
/// the same convention as `TopicBoundary.unitIndex` and
/// `SegmentationMetrics`.
struct ScriptedTranscript: Sendable, CustomTestStringConvertible {
    struct Exchange: Sendable {
        let user: String
        let agent: String
    }

    let name: String
    let exchanges: [Exchange]
    let boundaries: [Int]
    /// Length of each exchange on the audio timeline.
    var exchangeDuration: Duration = .seconds(20)
    /// Exchanges that belong to a brief digression the segmenter must not
    /// split out.
    var digression: Range<Int>?

    var testDescription: String { name }

    var count: Int { exchanges.count }

    /// The exchanges as segmenter units, back to back on the timeline.
    func units() -> [TopicUnit] {
        let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return exchanges.enumerated().map { index, exchange in
            let start = exchangeDuration * index
            return TopicUnit(
                id: UUID(uuid: Self.uuidBytes(index)),
                userText: exchange.user,
                agentText: exchange.agent,
                timeRange: TimeRange(start: start, duration: exchangeDuration),
                startedAt: origin.addingTimeInterval(start.timeInterval)
            )
        }
    }

    private static func uuidBytes(_ index: Int) -> uuid_t {
        let low = UInt8(index & 0xff)
        let high = UInt8((index >> 8) & 0xff)
        return (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low)
    }
}

private func exchange(_ user: String, _ agent: String) -> ScriptedTranscript.Exchange {
    ScriptedTranscript.Exchange(user: user, agent: agent)
}

extension ScriptedTranscript {
    static let all: [ScriptedTranscript] = [threeTopics, briefDigression, explicitCues, singleTopic, fourTopics]

    /// Three clearly separated topics of six exchanges each.
    static let threeTopics = ScriptedTranscript(
        name: "threeTopics",
        exchanges: [
            // Sourdough
            exchange(
                "I want to finally bake sourdough bread this weekend. My starter has been bubbling on the counter for a week.",
                "A week old starter is usually ready for bread. Feed the starter the night before you bake so it peaks when you mix the dough."
            ),
            exchange(
                "What flour should I use for the dough?",
                "Bread flour gives the dough more gluten and structure. Mix in some whole wheat flour for flavor and to feed the starter's yeast."
            ),
            exchange(
                "How long should the dough rise before shaping?",
                "Bulk fermentation usually takes four to six hours at room temperature. Look for the dough to grow by half and show bubbles on the sides."
            ),
            exchange(
                "My last loaf came out flat and dense. Was the dough overproofed?",
                "A flat loaf is often overproofed dough or weak gluten. Try stretch and folds during the bulk rise and shape the loaf with more surface tension."
            ),
            exchange(
                "Should I bake the loaf in a dutch oven?",
                "Yes, a preheated dutch oven traps steam so the loaf gets oven spring and a crisp crust. Bake covered for twenty minutes, then uncover to brown the crust."
            ),
            exchange(
                "How do I know the bread is done baking?",
                "The crust should be deep brown and the loaf should sound hollow when tapped. An internal temperature around 208 degrees means the crumb is baked through."
            ),
            // Marathon training
            exchange(
                "I signed up for my first marathon in April and I'm nervous about the training.",
                "Sixteen to eighteen weeks of marathon training is plenty. Build your weekly mileage slowly and keep most runs at an easy conversational pace."
            ),
            exchange(
                "How long should my long run be each week?",
                "Increase the long run by a mile or two each week, topping out around twenty miles three weeks before the race. Every few weeks, cut the mileage back to recover."
            ),
            exchange(
                "My knees ache after running on pavement. Should I worry?",
                "Knee pain from running often comes from ramping mileage too fast or worn running shoes. Mix in softer trails, strength work for your hips, and rest days."
            ),
            exchange(
                "What should I eat during the race?",
                "Practice race fueling on your long runs: take an energy gel or chews every forty five minutes and sip water or electrolytes at the aid stations."
            ),
            exchange(
                "How should I pace the first half of the marathon?",
                "Start slower than your goal marathon pace for the first few miles. A negative split, running the second half faster, avoids hitting the wall around mile twenty."
            ),
            exchange(
                "What about tapering before race day?",
                "Taper by cutting your weekly running mileage about thirty percent each of the last three weeks while keeping a few short runs at race pace so your legs stay sharp."
            ),
            // Refinancing
            exchange(
                "Interest rates dropped and I'm wondering whether to refinance our mortgage.",
                "Refinancing makes sense when the new mortgage rate is low enough that the monthly savings repay the closing costs within a few years."
            ),
            exchange(
                "What closing costs should I expect on a refinance?",
                "Refinance closing costs usually run two to five percent of the loan balance, covering the appraisal, title insurance, and lender origination fees."
            ),
            exchange(
                "Should I pick a fifteen year or thirty year loan?",
                "A fifteen year mortgage has a lower interest rate and builds home equity faster, but the monthly payment is higher than a thirty year loan."
            ),
            exchange(
                "Is paying points to lower the rate worth it?",
                "Mortgage points cost one percent of the loan each and typically cut the interest rate about a quarter point. Divide the cost by the monthly savings to find the break even."
            ),
            exchange(
                "Does my credit score affect the refinance rate?",
                "Yes, lenders price the mortgage rate on your credit score and loan to value ratio. A score above 760 and at least twenty percent home equity gets the best refinance rates."
            ),
            exchange(
                "What documents does the lender need?",
                "Lenders ask for recent pay stubs, two years of tax returns, bank statements, and your current mortgage statement to underwrite the refinance loan."
            ),
        ],
        boundaries: [6, 12]
    )

    /// One topic, a two-exchange digression, back to the same topic, then a
    /// real change. The digression must not become a topic.
    static let briefDigression = ScriptedTranscript(
        name: "briefDigression",
        exchanges: [
            // YC interview prep
            exchange(
                "I'm applying to Y Combinator next week and want to practice the interview.",
                "The YC interview is ten minutes of rapid questions from the partners. Practice answering what your startup does in one clear sentence."
            ),
            exchange(
                "How should I explain what our startup does?",
                "Describe the product and the customer plainly: who uses it and what problem it solves. Partners want the startup explained without buzzwords."
            ),
            exchange(
                "They'll probably ask about traction. We have forty paying customers.",
                "Lead with traction: forty paying customers and your monthly revenue growth rate. Partners care about growth and how fast customers are adopting the product."
            ),
            exchange(
                "What if they ask why our founders are the right team?",
                "Explain how the founders know each other and why your team has unique insight into the customer's problem. Mention who writes the code on the founding team."
            ),
            exchange(
                "How do I answer questions about competitors?",
                "Name the competitors honestly and explain what your startup understands that they miss. Partners distrust founders who claim to have no competition."
            ),
            exchange(
                "Should we talk about our fundraising plans in the interview?",
                "Keep it brief: say how much you plan to raise after Demo Day and what milestones the money funds. Spend most of the interview on the product, customers, and growth."
            ),
            // Digression: the espresso machine
            exchange(
                "Hold on, my espresso machine is making a weird grinding noise.",
                "A grinding espresso machine often means the grinder burrs are clogged with oily coffee beans. Clean the burrs and descale the boiler."
            ),
            exchange(
                "Should I use a darker roast for espresso then?",
                "Darker roasts are oilier and clog grinders faster. A medium roast coffee pulls a sweeter espresso shot and keeps the burrs cleaner."
            ),
            // Back to YC
            exchange(
                "Anyway, back to the interview. What's the hardest question partners ask?",
                "Partners often ask what your startup's biggest risk is. Answer directly, then explain how the founders plan to reduce that risk."
            ),
            exchange(
                "Should I bring a demo of the product to the interview?",
                "Have the product demo ready on a phone, but only show it if partners ask. The interview is mostly conversation about customers and growth."
            ),
            exchange(
                "How many mock interviews should our founders do?",
                "Do at least five mock interviews with alumni founders. Practice crisp answers on traction, customers, and competitors until the founding team sounds natural."
            ),
            exchange(
                "What happens after the interview if YC accepts us?",
                "YC calls accepted founders the same evening. The startup joins the batch, receives the standard deal, and works toward Demo Day with the partners."
            ),
            // Trip to Japan
            exchange(
                "After all that, I'm planning a trip to Japan in the spring.",
                "Spring in Japan is cherry blossom season. Book hotels in Tokyo and Kyoto early because they fill up fast in late March."
            ),
            exchange(
                "Is the Japan Rail Pass worth buying?",
                "The rail pass pays off if you ride the shinkansen bullet train between Tokyo, Kyoto, and Hiroshima. For a single Tokyo to Kyoto round trip, separate train tickets can be cheaper."
            ),
            exchange(
                "How many days should we spend in Kyoto?",
                "Three days in Kyoto covers the main temples and shrines, like Fushimi Inari and Kinkakuji, plus a day trip to the deer park in Nara."
            ),
            exchange(
                "What food should we try in Osaka?",
                "Osaka is known for street food: takoyaki, okonomiyaki, and kushikatsu around Dotonbori. Try a conveyor belt sushi bar too."
            ),
            exchange(
                "Do we need cash in Japan or are cards fine?",
                "Carry some yen in cash because small restaurants, temples, and shrines often don't take cards. Load a Suica card for trains and convenience stores."
            ),
            exchange(
                "Any tips for the cherry blossom crowds in Tokyo?",
                "Visit popular cherry blossom parks like Ueno and Shinjuku Gyoen early in the morning on a weekday, and check the bloom forecast before the trip."
            ),
        ],
        boundaries: [12],
        digression: 6..<8
    )

    /// Topic changes the user announces ("let's switch gears", "new topic").
    static let explicitCues = ScriptedTranscript(
        name: "explicitCues",
        exchanges: [
            // Vegetable garden
            exchange(
                "My tomato plants have yellow leaves at the bottom.",
                "Yellow lower leaves on tomato plants often mean overwatering or a nitrogen shortage. Water the garden soil deeply but less often, and add compost."
            ),
            exchange(
                "Should I prune the tomato suckers?",
                "Pruning suckers on indeterminate tomato plants focuses energy on fruit. Pinch them off when they're small, early in the morning."
            ),
            exchange(
                "What can I plant next to tomatoes in the garden bed?",
                "Basil, marigolds, and carrots are good companion plants for tomatoes. Marigolds help keep pests away from the garden bed."
            ),
            exchange(
                "Aphids are all over my pepper plants.",
                "Spray aphids off pepper plants with a strong stream of water, or use insecticidal soap. Ladybugs in the garden eat aphids too."
            ),
            exchange(
                "When should I harvest the peppers and tomatoes?",
                "Harvest tomatoes when they're fully colored and slightly soft. Peppers can be picked green or left on the plant to ripen red."
            ),
            // Kubernetes
            exchange(
                "Okay, let's switch gears. Our Kubernetes deployment keeps crashing in production.",
                "Check whether the pods are in CrashLoopBackOff. Run kubectl describe pod and kubectl logs to see why the container exits."
            ),
            exchange(
                "The logs show the container running out of memory.",
                "The container is probably hitting its memory limit and getting OOMKilled. Raise the memory limit in the deployment manifest or fix the leak in the service."
            ),
            exchange(
                "How do we roll back the deployment safely?",
                "Use kubectl rollout undo on the deployment to return to the previous replica set. Kubernetes replaces the pods gradually so the service stays up."
            ),
            exchange(
                "Should we add autoscaling to the cluster?",
                "A horizontal pod autoscaler adds pods when CPU or memory usage rises. Pair it with the cluster autoscaler so Kubernetes can add nodes."
            ),
            exchange(
                "How do we stop bad deployments from reaching production?",
                "Add readiness probes so Kubernetes only routes traffic to healthy pods, and use a canary deployment in the cluster before the full rollout."
            ),
            // Birthday party
            exchange(
                "New topic: my daughter turns seven next month and wants a birthday party.",
                "A seventh birthday party works well with ten to twelve kids for about two hours. Pick a theme your daughter loves, like unicorns or dinosaurs."
            ),
            exchange(
                "Should we host the party at home or at a venue?",
                "Hosting the birthday party at home is cheaper, but a trampoline park or bowling venue handles the kids' games and cleanup for you."
            ),
            exchange(
                "What games can the kids play at the party?",
                "Classic party games like a scavenger hunt, musical chairs, and a piñata keep seven year old kids busy between cake and presents."
            ),
            exchange(
                "How big a cake do we need for twelve kids?",
                "An eight inch round birthday cake serves about twelve kids. Cupcakes are easier to hand out and kids can decorate them at the party."
            ),
            exchange(
                "What should go in the party favor bags?",
                "Fill party favor bags with stickers, bubbles, a small toy, and candy that matches the birthday theme. Hand them to kids as parents pick them up."
            ),
        ],
        boundaries: [5, 10]
    )

    /// Fourteen exchanges on one subject. Any boundary is a false positive.
    static let singleTopic = ScriptedTranscript(
        name: "singleTopic",
        exchanges: [
            exchange(
                "I'm forty and just started learning piano. Is it too late?",
                "It's never too late to learn piano. Adults practice more deliberately and often progress quickly through beginner piano pieces."
            ),
            exchange(
                "How long should I practice piano each day?",
                "Thirty minutes of focused piano practice daily beats a long session once a week. Split practice into scales, sight reading, and a piece."
            ),
            exchange(
                "Should I learn to read sheet music or play by ear?",
                "Learn to read sheet music early; it unlocks every piano piece. Playing by ear is a great complement once you know the notes on the keys."
            ),
            exchange(
                "Which scales should a beginner pianist practice?",
                "Start with the C major scale, then G and F major. Practice hands separately, then together, with the standard piano fingering."
            ),
            exchange(
                "My left hand is much weaker than my right.",
                "Most pianists start with a weaker left hand. Practice the left hand part of each piece alone and play left hand scales slowly."
            ),
            exchange(
                "Should I buy a digital piano or an acoustic piano?",
                "A digital piano with weighted keys is fine for a beginner and needs no tuning. An acoustic piano has a richer tone but costs more."
            ),
            exchange(
                "What beginner pieces are good for adult piano students?",
                "Try Bach's Minuet in G, Satie's Gymnopédie, and simple arrangements of pop songs. Choose pieces slightly above your piano level."
            ),
            exchange(
                "How do I use a metronome for piano practice?",
                "Set the metronome slow enough to play the piece without mistakes, then raise the tempo a few beats per minute each practice session."
            ),
            exchange(
                "Is it worth taking piano lessons with a teacher?",
                "A piano teacher catches bad habits in hand posture and fingering that are hard to notice yourself. Even monthly lessons help."
            ),
            exchange(
                "My fingers get tense when I play fast passages.",
                "Tension usually means the tempo is too fast. Relax the wrist, keep the fingers curved over the keys, and practice the passage slowly."
            ),
            exchange(
                "How do I memorize a piano piece?",
                "Memorize the piece in small sections, hands separately, and learn the chord structure. Play from memory away from the piano in your head."
            ),
            exchange(
                "Should I learn chords for playing pop songs on piano?",
                "Learning chords lets you play pop songs from lead sheets. Practice major and minor chords and their inversions across the keys."
            ),
            exchange(
                "How do I use the sustain pedal properly?",
                "Press the sustain pedal just after you play the new chord and lift it as the chord changes, so the notes don't blur together."
            ),
            exchange(
                "How long until I can play intermediate piano pieces?",
                "With daily practice, many adult piano students reach intermediate pieces like Chopin's easier waltzes in two to three years."
            ),
        ],
        boundaries: []
    )

    /// Four topics of uneven length with shorter exchanges.
    static let fourTopics = ScriptedTranscript(
        name: "fourTopics",
        exchanges: [
            // Car maintenance
            exchange(
                "My car's check engine light came on this morning.",
                "A check engine light can be a loose gas cap or a misfire. An OBD2 scanner reads the engine code so you know what the car needs."
            ),
            exchange(
                "The scanner says P0301, cylinder one misfire.",
                "A cylinder one misfire usually points to a bad spark plug or ignition coil. Swap the coil with cylinder two and see if the misfire moves."
            ),
            exchange(
                "How often should spark plugs be replaced?",
                "Most modern engines need new spark plugs every sixty thousand to one hundred thousand miles. Check the car's maintenance schedule."
            ),
            exchange(
                "When should I change the engine oil?",
                "Synthetic engine oil usually lasts five to seven thousand miles. Change the oil filter at every oil change."
            ),
            exchange(
                "My brakes squeal when I stop.",
                "Squealing brakes often mean the brake pads' wear indicators are touching the rotors. Replace the pads soon and inspect the rotors."
            ),
            exchange(
                "Should I rotate the tires myself?",
                "Rotate tires every five thousand miles to even out tread wear. Torque the lug nuts to spec after the tire rotation."
            ),
            exchange(
                "Is it worth buying an extended car warranty?",
                "Extended car warranties rarely pay off for a reliable car. Put the money aside for repairs and keep up with the car's maintenance."
            ),
            // Taxes
            exchange(
                "I need to file my taxes and I have freelance income this year.",
                "Freelance income goes on Schedule C, and you owe self employment tax on the profit. Keep records of every business expense."
            ),
            exchange(
                "Can I deduct my home office?",
                "If you use the room only for business, the home office deduction lets you deduct a share of rent and utilities, or use the simplified rate per square foot."
            ),
            exchange(
                "Should I pay estimated taxes each quarter?",
                "Freelancers who owe over a thousand dollars should pay quarterly estimated taxes to the IRS to avoid underpayment penalties."
            ),
            exchange(
                "What about contributing to a retirement account for tax savings?",
                "A SEP IRA or solo 401k lets self employed filers deduct retirement contributions and lower taxable income."
            ),
            exchange(
                "When is the tax filing deadline?",
                "The federal tax filing deadline is April fifteenth. You can file an extension, but any taxes owed are still due by the deadline."
            ),
            // Puppy training
            exchange(
                "We adopted a puppy and she keeps chewing the furniture.",
                "Puppies chew while teething. Give her chew toys, and redirect her from the furniture to a toy every time she chews."
            ),
            exchange(
                "How do I house train the puppy?",
                "Take the puppy outside after meals, naps, and play, and reward her right after she goes. Crate training helps with house training."
            ),
            exchange(
                "She pulls hard on the leash during walks.",
                "Stop walking whenever the dog pulls and reward her when the leash is loose. A front clip harness reduces leash pulling."
            ),
            exchange(
                "How do I teach her to come when called?",
                "Practice recall in a quiet yard with high value treats. Say her name and come, then reward the dog generously every time."
            ),
            exchange(
                "Should we sign up for puppy obedience classes?",
                "Puppy classes teach basic obedience and socialize her with other dogs. Look for a trainer who uses positive reinforcement."
            ),
            exchange(
                "She barks at every dog she sees on walks.",
                "Reactive barking improves with distance. Reward her with treats when she sees another dog calmly, and slowly decrease the distance."
            ),
            // Podcast launch
            exchange(
                "I want to launch a podcast about local history.",
                "A local history podcast can find a loyal audience. Plan ten episodes before launch so you can publish on a steady schedule."
            ),
            exchange(
                "What microphone should I buy for recording?",
                "A USB dynamic microphone like the Samson Q2U records clean podcast audio in untreated rooms and costs under a hundred dollars."
            ),
            exchange(
                "Which software should I use to edit episodes?",
                "Audacity is free and handles podcast editing well. Descript lets you edit the episode audio by editing the transcript."
            ),
            exchange(
                "Where do I host the podcast feed?",
                "A podcast host like Buzzsprout or Transistor stores your episode files and publishes the RSS feed to Apple Podcasts and Spotify."
            ),
            exchange(
                "How long should each episode be?",
                "Twenty to forty minute episodes suit a history podcast. Keep the episode length consistent so listeners know what to expect."
            ),
            exchange(
                "How do I grow the podcast audience?",
                "Invite local historians as guests, share episode clips on social media, and ask listeners to rate the podcast on Apple Podcasts."
            ),
        ],
        boundaries: [7, 12, 18],
        exchangeDuration: .seconds(18)
    )
}
