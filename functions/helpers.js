const admin = require("firebase-admin");

function db() {
  return admin.firestore();
}

// ---------------------------------------------------------------------------
// Config — mirrors AdminConfigService's defaults exactly so behaviour
// doesn't silently change just because this logic now also runs server-side.
// ---------------------------------------------------------------------------
async function getSystemSettings() {
  const doc = await db().collection("admin_configs").doc("system_settings").get();
  return doc.exists ? doc.data() : null;
}

async function getMaxUnitsPerTeacher() {
  const s = await getSystemSettings();
  return (s && typeof s.maxUnitsPerTeacher === "number") ? s.maxUnitsPerTeacher : 24;
}

async function getUnifiedCutoffTime() {
  const s = await getSystemSettings();
  if (s && s.unifiedCutoffTime) return s.unifiedCutoffTime;
  if (s && s.sameDayLeaveCutoffTime) return s.sameDayLeaveCutoffTime;
  return "12:45";
}

async function isPastUnifiedCutoffNow() {
  const cutoff = await getUnifiedCutoffTime();
  const parts = cutoff.split(":");
  if (parts.length !== 2) return false;
  const hour = parseInt(parts[0], 10);
  const minute = parseInt(parts[1], 10);
  if (Number.isNaN(hour) || Number.isNaN(minute)) return false;
  const now = new Date();
  const cutoffDateTime = new Date(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute);
  return now.getTime() > cutoffDateTime.getTime();
}

function dateKeyFor(date) {
  const y = String(date.getFullYear()).padStart(4, "0");
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

// ---------------------------------------------------------------------------
// Time-overlap math — exact port of FixtureService._minutesOf/_overlaps.
// ---------------------------------------------------------------------------
function minutesOf(t) {
  if (!t) return null;
  const trimmed = t.trim();
  if (!trimmed) return null;
  const m = /^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?$/.exec(trimmed);
  if (!m) return null;
  let hour = parseInt(m[1], 10);
  const minute = parseInt(m[2], 10);
  const ampm = m[3];
  if (ampm) {
    const isPM = ampm.toUpperCase() === "PM";
    if (hour === 12) {
      hour = isPM ? 12 : 0;
    } else {
      hour = isPM ? hour + 12 : hour;
    }
  }
  return hour * 60 + minute;
}

function overlaps(aStart, aEnd, bStart, bEnd) {
  const s1 = minutesOf(aStart);
  const e1 = minutesOf(aEnd);
  const s2 = minutesOf(bStart);
  const e2 = minutesOf(bEnd);
  if (s1 == null || e1 == null || s2 == null || e2 == null) return false;
  return s1 < e2 && s2 < e1;
}

// ---------------------------------------------------------------------------
// Live permanent weekly load — same fix as UserService.getLivePermanentUnits.
// Computed from weekly_timetables, never trusted from a stored field.
// ---------------------------------------------------------------------------
async function livePermanentUnits(teacherId) {
  if (!teacherId) return 0;
  const snap = await db()
    .collection("weekly_timetables")
    .where("teacherId", "==", teacherId)
    .get();
  return snap.size;
}

// ---------------------------------------------------------------------------
// Clamped, never-negative fixtureUnits adjustment — exact port of
// FixtureService._safeAdjustFixtureUnits. The caller must already have read
// userRef inside the SAME transaction (Firestore requires all reads before
// any writes), and pass that read's current value in.
// ---------------------------------------------------------------------------
function applySafeFixtureUnitsAdjustment(tx, userRef, currentValue, delta) {
  const next = (currentValue || 0) + delta;
  tx.update(userRef, { fixtureUnits: next < 0 ? 0 : next });
}

// ---------------------------------------------------------------------------
// Leave check — exact port of FixtureService._isTeacherOnApprovedLeave.
// ---------------------------------------------------------------------------
async function isTeacherOnApprovedLeave(teacherId, dateKey) {
  const parts = dateKey.split("-");
  if (parts.length !== 3) return false;
  const date = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));

  const snap = await db()
    .collection("leave_requests")
    .where("teacherId", "==", teacherId)
    .where("status", "==", "approved")
    .get();

  for (const doc of snap.docs) {
    const data = doc.data();
    const start = data.startDate ? data.startDate.toDate() : null;
    const end = data.endDate ? data.endDate.toDate() : start;
    if (!start) continue;
    const s = new Date(start.getFullYear(), start.getMonth(), start.getDate());
    const e = new Date(end.getFullYear(), end.getMonth(), end.getDate());
    if (date.getTime() >= s.getTime() && date.getTime() <= e.getTime()) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// "Is this teacher actually free for this fixture" — exact port of
// FixtureService.isTeacherFreeForFixture.
// ---------------------------------------------------------------------------
async function isTeacherFreeForFixture(fixture, teacherId) {
  if (fixture.date) {
    const onLeave = await isTeacherOnApprovedLeave(teacherId, fixture.date);
    if (onLeave) return false;
  }

  const weeklyBusySnap = await db()
    .collection("weekly_timetables")
    .where("teacherId", "==", teacherId)
    .get();
  for (const d of weeklyBusySnap.docs) {
    const data = d.data();
    if ((data.day || "") !== fixture.day) continue;
    if (overlaps(fixture.startTime, fixture.endTime, data.startTime || "", data.endTime || "")) {
      return false;
    }
  }

  if (fixture.date) {
    const exceptionBusySnap = await db()
      .collection("timetable_exceptions")
      .where("date", "==", fixture.date)
      .where("teacherId", "==", teacherId)
      .get();
    for (const d of exceptionBusySnap.docs) {
      const data = d.data();
      if (overlaps(fixture.startTime, fixture.endTime, data.startTime || "", data.endTime || "")) {
        return false;
      }
    }
  }

  const otherClaimedSnap = await db()
    .collection("fixtures")
    .where("claimedBy", "==", teacherId)
    .get();
  for (const d of otherClaimedSnap.docs) {
    if (d.id === fixture.id) continue;
    const data = d.data();
    if ((data.day || "") !== fixture.day) continue;
    if (overlaps(fixture.startTime, fixture.endTime, data.startTime || "", data.endTime || "")) {
      return false;
    }
  }

  return true;
}

// ---------------------------------------------------------------------------
// Reverts a covered timetable_exceptions doc back to a plain vacancy — exact
// port of TimetableService.revertSlotToVacantForDate, used when a release
// (self or via the expiry sweep) needs to un-cover the underlying slot.
// ---------------------------------------------------------------------------
async function revertSlotToVacantForDate(slotId, date) {
  if (!slotId || !date) return;
  const ref = db().collection("timetable_exceptions").doc(`${slotId}_${date}`);
  const snap = await ref.get();
  if (!snap.exists) return;
  await ref.set(
    {
      type: "leave",
      teacherId: "",
      teacherName: "",
      sourceId: "",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

async function isAdminUid(uid) {
  if (!uid) return false;
  const doc = await db().collection("admins").doc(uid).get();
  return doc.exists;
}

module.exports = {
  db,
  getSystemSettings,
  getMaxUnitsPerTeacher,
  getUnifiedCutoffTime,
  isPastUnifiedCutoffNow,
  dateKeyFor,
  minutesOf,
  overlaps,
  livePermanentUnits,
  applySafeFixtureUnitsAdjustment,
  isTeacherOnApprovedLeave,
  isTeacherFreeForFixture,
  revertSlotToVacantForDate,
  isAdminUid,
};
