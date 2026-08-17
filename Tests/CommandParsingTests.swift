import Testing
import Foundation
@testable import PersonalAssistant

/// One test per sentence named in requirement 19, plus the ones from requirement 4.
/// All of these run through the offline rules layer only — no model, no network, no device.
@Suite("Natural language → structured command")
struct CommandParsingTests {

    // MARK: - English

    @Test("Remind me tomorrow at 4 to call Riad")
    func tomorrowAtFour() throws {
        let command = Fixture.parse("Remind me tomorrow at 4 to call Riad.")
        #expect(command.action == .createAlarm)
        #expect(command.title == "call Riad")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.day == 20)
        #expect(parts.hour == 16, "a bare 4 in a reminder reads as the afternoon")
        #expect(command.meridiemWasGuessed, "so the chat can offer a one-tap 4 AM correction")
        #expect(command.confidence >= Constants.ruleConfidenceThreshold)
    }

    @Test("Alarm at 7 for gym")
    func alarmAtSevenForGym() throws {
        let command = Fixture.parse("Alarm at 7 for gym.")
        #expect(command.action == .createAlarm)
        #expect(command.title == "gym")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.hour == 7, "a bare 7 reads as the morning")
        #expect(parts.day == 20, "07:00 today has already passed at 10:00, so it rolls to tomorrow")
        #expect(command.rolledForward)
    }

    @Test("Remind me in 5 minutes to test this")
    func inFiveMinutes() throws {
        let command = Fixture.parse("Remind me in 5 minutes to test this.")
        #expect(command.action == .createAlarm)
        #expect(command.title == "test this")
        #expect(try #require(command.scheduledAt).timeIntervalSince(Fixture.now) == 300)
        #expect(!command.meridiemWasGuessed)
    }

    @Test("Every Monday at 9 remind me to send the report")
    func everyMonday() throws {
        let command = Fixture.parse("Every Monday at 9 remind me to send the report.")
        #expect(command.action == .createAlarm)
        #expect(command.title == "send the report")
        #expect(command.recurrence == .weekly(days: [2]))
        #expect(command.recurrence.isNativelySupportedByAlarmKit,
                "weekly is the one recurrence AlarmKit repeats by itself")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.weekday == 2)
        #expect(parts.day == 24, "the first Monday after Wednesday the 19th")
        #expect(parts.hour == 9)
    }

    @Test("Wake me every weekday at 7")
    func everyWeekday() throws {
        let command = Fixture.parse("Wake me every weekday at 7.")
        #expect(command.action == .createAlarm)
        #expect(command.recurrence == .weekly(days: RecurrenceRule.allWeekdays))
        #expect(command.title == "Wake up")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.hour == 7)
        #expect(parts.day == 20, "07:00 Wednesday has passed, so the first one is Thursday")
    }

    @Test("Remind me every 3 days to check this")
    func everyThreeDays() {
        let command = Fixture.parse("Remind me every 3 days to check this.")
        #expect(command.action == .createAlarm)
        #expect(command.recurrence == .everyNDays(3))
        #expect(!command.recurrence.isNativelySupportedByAlarmKit,
                "this is the case AlarmKit cannot express — it must go through the rolling window")
        #expect(command.title == "check this")
        #expect(command.timeWasDefaulted, "no time was named, so the default reminder hour is used")
        #expect(command.scheduledAt != nil, "a rhythm with no clock time must still resolve")
    }

    @Test("Postpone that until tomorrow at 3")
    func postponeUntilTomorrowAtThree() throws {
        let command = Fixture.parse("Postpone that until tomorrow at 3.")
        #expect(command.action == .postponeAlarm)

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.day == 20)
        #expect(parts.hour == 15, "the 'at 3' belongs to the same trailing phrase as 'until tomorrow'")
        #expect(command.targetAt == nil, "nothing in the sentence describes the existing alarm")
    }

    @Test("Move the IBM thing to Friday")
    func moveToFriday() throws {
        let command = Fixture.parse("Move the IBM thing to Friday.")
        #expect(command.action == .postponeAlarm)
        #expect(command.targetQuery == "IBM thing")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.weekday == 6)
        #expect(parts.day == 21)
        #expect(command.timeWasDefaulted, "no time given, so the executor keeps the original one")
    }

    @Test("Postpone the Riad alarm until Friday at 11")
    func postponeRiadUntilFriday() throws {
        let command = Fixture.parse("Postpone the Riad alarm until Friday at 11.")
        #expect(command.action == .postponeAlarm)
        #expect(command.targetQuery == "Riad")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.day == 21)
        #expect(parts.hour == 11)
    }

    @Test("Cancel my 4 PM alarm")
    func cancelFourPM() throws {
        let command = Fixture.parse("Cancel my 4 PM alarm.")
        #expect(command.action == .cancelAlarm)
        #expect(command.targetHasClock)
        #expect(command.scheduledAt == nil, "a cancel has no new time")

        let parts = Fixture.parts(try #require(command.targetAt))
        #expect(parts.hour == 16)
        #expect(parts.day == 19, "16:00 today is still ahead of 10:00")
    }

    @Test("Cancel tomorrow's dentist alarm")
    func cancelDentist() throws {
        let command = Fixture.parse("Cancel tomorrow's dentist alarm.")
        #expect(command.action == .cancelAlarm)
        #expect(command.targetQuery == "dentist")
        #expect(!command.targetHasClock, "only a day was named, so matching is day-wide")
        #expect(Fixture.parts(try #require(command.targetAt)).day == 20)
    }

    @Test("Move gym until 8")
    func moveGym() throws {
        let command = Fixture.parse("Move gym until 8.")
        #expect(command.action == .postponeAlarm)
        #expect(command.targetQuery == "gym")
        #expect(Fixture.parts(try #require(command.scheduledAt)).hour == 8)
    }

    @Test("What's next?")
    func whatsNext() {
        #expect(Fixture.parse("What's next?").action == .getNextItems)
        #expect(Fixture.parse("whats next").action == .getNextItems)
        #expect(Fixture.parse("shu ba3d?").action == .getNextItems)
    }

    @Test("What alarms do I have tomorrow?")
    func listTomorrow() throws {
        let command = Fixture.parse("What alarms do I have tomorrow?")
        #expect(command.action == .listAlarms)
        #expect(Fixture.parts(try #require(command.scheduledAt)).day == 20)
    }

    @Test("I finished the HRFS task")
    func finishedTask() {
        let command = Fixture.parse("I finished the HRFS task.")
        #expect(command.action == .markCompleted)
        #expect(command.targetQuery == "HRFS task")
        #expect(command.confidence >= Constants.ruleConfidenceThreshold)
    }

    // MARK: - Arabic

    @Test("ذكرني بكرا الساعة ٤ اتصل برياض")
    func arabicReminder() throws {
        let command = Fixture.parse("ذكرني بكرا الساعة ٤ اتصل برياض")
        #expect(command.action == .createAlarm)
        #expect(command.title == "اتصل برياض", "the user's own words survive into the title")
        #expect(command.detectedScript == TextScript.arabic.rawValue)

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.day == 20, "بكرا = tomorrow")
        #expect(parts.hour == 16, "٤ was normalised to 4 and read as the afternoon")
    }

    @Test("أجّل موعد بكرا للجمعة")
    func arabicPostpone() throws {
        let command = Fixture.parse("أجّل موعد بكرا للجمعة")
        #expect(command.action == .postponeAlarm)

        // "للجمعة" fuses "to" onto "Friday", so it is the new time...
        let newTime = Fixture.parts(try #require(command.scheduledAt))
        #expect(newTime.weekday == 6)
        #expect(newTime.day == 21)

        // ...while "بكرا" carries no marker and therefore describes the alarm being moved.
        #expect(Fixture.parts(try #require(command.targetAt)).day == 20)
    }

    @Test("Arabic normalisation is spelling-insensitive")
    func arabicNormalisation() {
        // Harakat, alef forms, ta marbuta and Arabic-Indic digits must not change the reading.
        let plain = Fixture.parse("ذكرني بكرا الساعة 4 اتصل برياض")
        let decorated = Fixture.parse("ذكِّرني بُكرا الساعه ٤ اتصل برياض")
        #expect(plain.scheduledAt == decorated.scheduledAt)
        #expect(plain.action == decorated.action)
    }

    // MARK: - Arabizi

    @Test("zakkerne bokra 4 etsel b Riad")
    func arabiziReminder() throws {
        let command = Fixture.parse("zakkerne bokra 4 etsel b Riad")
        #expect(command.action == .createAlarm)
        #expect(command.title == "etsel b Riad")

        let parts = Fixture.parts(try #require(command.scheduledAt))
        #expect(parts.day == 20)
        #expect(parts.hour == 16)
        #expect(command.confidence >= Constants.ruleConfidenceThreshold,
                "Arabizi must clear the bar without help — Apple's model does not support it")
    }

    @Test("zakkerne bokra se3a 4 etsel b Riad")
    func arabiziWithOclock() throws {
        let command = Fixture.parse("zakkerne bokra se3a 4 etsel b Riad")
        #expect(command.action == .createAlarm)
        #expect(command.title == "etsel b Riad")
        #expect(Fixture.parts(try #require(command.scheduledAt)).hour == 16)
    }

    @Test("3melle alarm 7 lal gym")
    func arabiziAlarm() throws {
        let command = Fixture.parse("3melle alarm 7 lal gym")
        #expect(command.action == .createAlarm)
        #expect(command.title == "gym")
        #expect(Fixture.parts(try #require(command.scheduledAt)).hour == 7)
    }

    @Test("Arabizi is never sent to Apple's model")
    func arabiziIsRefusedByTheModel() {
        // The model has no Arabic training, so romanised Arabic would be read as English and
        // answered confidently and wrongly. It has to be blocked before it gets there.
        #expect(Normalizer.looksLikeArabizi(Normalizer.normalize("zakkerne bokra se3a 4")))
        #expect(Normalizer.looksLikeArabizi(Normalizer.normalize("3melle alarm 7 lal gym")))
        #expect(!Normalizer.looksLikeArabizi(Normalizer.normalize("Remind me tomorrow at 4")))
    }

    // MARK: - Nothing is ever lost

    @Test("Unreadable input still produces a keepable note")
    func unparseableFallsBack() {
        let command = Fixture.parse("qwertyuiop zxcvbnm")
        #expect(command.action == .saveNote)
        #expect(command.title == "qwertyuiop zxcvbnm", "the exact text survives")
        #expect(command.confidence < Constants.ruleConfidenceThreshold,
                "low confidence is what routes this to the one-tap form instead of a wrong alarm")
    }

    @Test("The original text is carried on every command")
    func originalTextIsPreserved() {
        for text in ["Remind me tomorrow at 4 to call Riad.",
                     "ذكرني بكرا الساعة ٤ اتصل برياض",
                     "3melle alarm 7 lal gym"] {
            #expect(Fixture.parse(text).originalText == text)
        }
    }

    @Test("A command survives a JSON round trip")
    func commandRoundTrips() throws {
        let command = Fixture.parse("Every Monday at 9 remind me to send the report.")
        let restored = try #require(AssistantCommand.fromJSON(command.jsonString))
        #expect(restored == command)
    }
}
