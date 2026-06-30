const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const h = require("./helpers");

admin.initializeApp();

// ---------------------------------------------------------------------------
// WHY THIS FILE EXISTS
//
// Several writes in this app are inherently cross-user: claiming a fixture
// changes the claimer's own fixtureUnits (fine, that's a self-write a
// security rule can validate), but releasing/expiring/auto-assigning can
// need to change a DIFFERENT teacher's fixtureUnits — e.g. the periodic
// expiry sweep, which runs from whichever teacher's session happens to have
// the app open (see main_navigation_screen.dart), decrementing the units of
// whoever's claim is expiring, which is essentially never the same person.
// Firestore security rules evaluate each document write independently, with
// no way to say "this write to someone else's doc is legitimate because it's
// paired with that OTHER write over there in the same transaction" across
// rule evaluations for two different documents. The only correct fix is to
// run this logic with trusted (Admin SDK) privileges, which is what these
// callables are. The CLIENT decides "I want to claim fixture X" or "sweep
// for expired fixtures now" — these functions are the only thing that can
// actually carry that out, and always trust `request.auth.uid` over
// anything else the client claims, which closes the "I claimed/released a
// fixture on someone else's behalf" gap the old direct-Firestore-write
// version had.
// ---------------------------------------------------------------------------

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  return request.auth.uid;
}

async function requireAdmin(request) {
  const uid = requireAuth(request);
  const ok = await h.isAdminUid(uid);
  if (!ok) {
    throw new HttpsError("permission-denied", "Admin only.");
  }
  return uid;
}

async function notifyTeacher(teacherId, title, body, type, data) {
  await h.db().collection("notifications").add({
    userId: teacherId,
    title,
    body,
    type: `NotificationType.${type}`,
    data: data || {},
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    read: false,
    senderId: "system",
  });
}

async function notifyAdmins(title, body, action, data) {
  const admins = await h.db().collection("admins").get();
  const batch = h.db().batch();
  for (const a of admins.docs) {
    batch.set(h.db().collection("notifications").doc(), {
      userId: a.id,
      title,
      body,
      type: "adminNotification",
      action,
      data: data || {},
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      read: false,
      senderId: "system",
    });
  }
  await batch.commit();
}

// ---------------------------------------------------------------------------
// claimFixture — self-claim only. teacherId is ALWAYS request.auth.uid,
// never read from the request payload, closing the "claim on someone else's
// behalf" gap the old client-trusted-teacherId version had.
// ---------------------------------------------------------------------------
exports.claimFixture = onCall(async (request) => {
  const teacherId = requireAuth(request);
  const fixtureId = request.data && request.data.fixtureId;
  if (!fixtureId) throw new HttpsError("invalid-argument", "fixtureId is required.");

  const userDoc = await h.db().collection("users").doc(teacherId).get();
  if (!userDoc.exists) throw new HttpsError("not-found", "Teacher profile not found.");
  const teacherName = userDoc.data().name || userDoc.data().email || "Teacher";

  const fixtureRef = h.db().collection("fixtures").doc(fixtureId);
  const preCheckDoc = await fixtureRef.get();
  if (!preCheckDoc.exists) throw new HttpsError("not-found", "Fixture not found.");
  const preCheck = preCheckDoc.data();

  const fixtureDate = preCheck.date || "";
  if (fixtureDate) {
    const todayKey = h.dateKeyFor(new Date());
    if (fixtureDate === todayKey && (await h.isPastUnifiedCutoffNow())) {
      throw new HttpsError("failed-precondition", "Same-day fixture claims are blocked after cutoff time.");
    }
    if (await h.isTeacherOnApprovedLeave(teacherId, fixtureDate)) {
      throw new HttpsError("failed-precondition", "You are on approved leave on this date.");
    }
  }

  const isFree = await h.isTeacherFreeForFixture({ id: fixtureId, ...preCheck }, teacherId);
  if (!isFree) {
    throw new HttpsError(
      "failed-precondition",
      "You already have a class (or another fixture) at this time."
    );
  }

  const defaultUnits = await h.livePermanentUnits(teacherId);
  const maxUnits = await h.getMaxUnitsPerTeacher();
  const currentFixtureUnits = userDoc.data().fixtureUnits || 0;
  if (defaultUnits + currentFixtureUnits >= maxUnits) {
    throw new HttpsError(
      "failed-precondition",
      `You have reached your ${maxUnits}-unit weekly limit and cannot claim more cover.`
    );
  }

  const userRef = h.db().collection("users").doc(teacherId);
  let committedFixture = null;

  await h.db().runTransaction(async (tx) => {
    const fixtureDoc = await tx.get(fixtureRef);
    if (!fixtureDoc.exists) throw new HttpsError("not-found", "Fixture not found.");
    const fixture = fixtureDoc.data();
    if (fixture.status !== "available") {
      throw new HttpsError(
        "failed-precondition",
        "Fixture is no longer available — someone else just claimed it."
      );
    }
    const expiresAt = fixture.expiresAt ? fixture.expiresAt.toDate() : null;
    if (expiresAt && new Date() > expiresAt) {
      throw new HttpsError("failed-precondition", "Fixture claim window has expired.");
    }

    const userSnap = await tx.get(userRef);
    const currentUnits = (userSnap.data() && userSnap.data().fixtureUnits) || 0;

    tx.update(fixtureRef, {
      claimedBy: teacherId,
      claimedByName: teacherName,
      status: "claimed",
      claimedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    h.applySafeFixtureUnitsAdjustment(tx, userRef, currentUnits, 1);

    committedFixture = fixture;
  });

  if (!committedFixture) return { ok: true };
  const fixture = committedFixture;

  const sourceSlotId = fixture.sourceDailySlotId;
  const date = fixture.date || "";
  if (sourceSlotId && date) {
    await h.db().collection("timetable_exceptions").doc(`${sourceSlotId}_${date}`).set(
      {
        slotId: sourceSlotId,
        date,
        type: "fixture_assigned",
        teacherId,
        teacherName,
        sourceId: fixtureId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }

  await h.db().collection("fixture_requests").add({
    fixtureId,
    teacherId,
    teacherName,
    action: "claimed",
    status: "active",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const className = fixture.className || "a class";
  const day = fixture.day || "";
  const unit = fixture.unit;
  await notifyTeacher(
    teacherId,
    "Cover confirmed",
    `You're now covering ${className} (unit ${unit}) on ${day}.`,
    "fixtureClaimed",
    { fixtureId }
  );
  await notifyAdmins(
    "Fixture claimed",
    `${teacherName} picked up ${className} (unit ${unit}, ${day}).`,
    "fixture_claimed",
    { fixtureId }
  );

  return { ok: true };
});

// ---------------------------------------------------------------------------
// releaseFixture — self-release by default. An admin caller may pass an
// explicit `teacherId` to release on behalf of someone else (this is what
// the leave-approval flow needs: when a teacher's leave is approved, any
// fixture THEY were covering for someone else has to be released too, and
// that release is triggered by the admin approving the leave, not by the
// affected teacher's own session).
// ---------------------------------------------------------------------------
exports.releaseFixture = onCall(async (request) => {
  const callerUid = requireAuth(request);
  const fixtureId = request.data && request.data.fixtureId;
  if (!fixtureId) throw new HttpsError("invalid-argument", "fixtureId is required.");

  let teacherId = request.data && request.data.teacherId;
  if (teacherId && teacherId !== callerUid) {
    const callerIsAdmin = await h.isAdminUid(callerUid);
    if (!callerIsAdmin) {
      throw new HttpsError("permission-denied", "Only an admin can release on someone else's behalf.");
    }
  } else {
    teacherId = callerUid;
  }

  const fixtureRef = h.db().collection("fixtures").doc(fixtureId);
  const userRef = h.db().collection("users").doc(teacherId);
  let released = null;

  await h.db().runTransaction(async (tx) => {
    const fixtureDoc = await tx.get(fixtureRef);
    if (!fixtureDoc.exists) throw new HttpsError("not-found", "Fixture not found.");
    const fixture = fixtureDoc.data();
    const currentHolder = fixture.claimedBy || fixture.assignedTeacherId || "";
    if (currentHolder !== teacherId) {
      throw new HttpsError("permission-denied", "That teacher doesn't currently hold this fixture.");
    }
    if (fixture.status === "available") {
      released = null;
      return;
    }

    const userSnap = await tx.get(userRef);
    const currentUnits = (userSnap.data() && userSnap.data().fixtureUnits) || 0;

    tx.update(fixtureRef, {
      claimedBy: null,
      claimedByName: null,
      assignedTeacherId: null,
      assignedTeacherName: null,
      status: "available",
      releasedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(request.data && request.data.releaseNote ? { releaseNote: request.data.releaseNote } : {}),
    });
    h.applySafeFixtureUnitsAdjustment(tx, userRef, currentUnits, -1);

    released = fixture;
  });

  if (!released) return { ok: true };

  const sourceSlotId = released.sourceDailySlotId;
  const date = released.date || "";
  if (sourceSlotId && date) {
    await h.revertSlotToVacantForDate(sourceSlotId, date);
  }

  const activeReq = await h
    .db()
    .collection("fixture_requests")
    .where("fixtureId", "==", fixtureId)
    .where("teacherId", "==", teacherId)
    .where("status", "==", "active")
    .limit(1)
    .get();
  if (!activeReq.empty) {
    await activeReq.docs[0].ref.update({
      status: "released",
      releasedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  return { ok: true };
});

// ---------------------------------------------------------------------------
// assignFixture — ADMIN ONLY. Admin specifies the target teacher directly
// (legitimate — an admin has authority to assign on someone else's behalf,
// unlike a peer teacher). Also used internally by the autoAssign sweep via
// `triggerAutoAssign` below, in which case the "admin" performing it is the
// trusted server context itself, not a real admin user.
// ---------------------------------------------------------------------------
async function doAssignFixture(fixtureId, teacherId, teacherName, actionLabel) {
  const fixtureRef = h.db().collection("fixtures").doc(fixtureId);
  const userRef = h.db().collection("users").doc(teacherId);

  const userDoc = await userRef.get();
  if (!userDoc.exists) throw new HttpsError("not-found", "Teacher not found.");
  const defaultUnits = await h.livePermanentUnits(teacherId);
  const maxUnits = await h.getMaxUnitsPerTeacher();

  let previousHolder = null;
  let committedFixture = null;

  await h.db().runTransaction(async (tx) => {
    const fixtureDoc = await tx.get(fixtureRef);
    if (!fixtureDoc.exists) throw new HttpsError("not-found", "Fixture not found.");
    const fixture = fixtureDoc.data();
    const expiresAt = fixture.expiresAt ? fixture.expiresAt.toDate() : null;
    if (expiresAt && new Date() < expiresAt) {
      throw new HttpsError("failed-precondition", "Can only assign fixtures after the claim window closes.");
    }

    const currentClaimedBy = fixture.claimedBy;
    if (currentClaimedBy && currentClaimedBy !== teacherId) {
      previousHolder = currentClaimedBy;
    }

    const assigneeSnap = await tx.get(userRef);
    const liveFixtureUnits = (assigneeSnap.data() && assigneeSnap.data().fixtureUnits) || 0;
    const alreadyCountsForThisFixture = currentClaimedBy === teacherId;
    const projectedFixtureUnits = alreadyCountsForThisFixture
      ? liveFixtureUnits
      : liveFixtureUnits + 1;

    if (defaultUnits + projectedFixtureUnits > maxUnits) {
      throw new HttpsError(
        "failed-precondition",
        `Assigning this fixture would exceed the teacher's ${maxUnits}-unit limit.`
      );
    }

    if (previousHolder) {
      const prevRef = h.db().collection("users").doc(previousHolder);
      const prevSnap = await tx.get(prevRef);
      const prevUnits = (prevSnap.data() && prevSnap.data().fixtureUnits) || 0;
      h.applySafeFixtureUnitsAdjustment(tx, prevRef, prevUnits, -1);
    }
    if (!alreadyCountsForThisFixture) {
      h.applySafeFixtureUnitsAdjustment(tx, userRef, liveFixtureUnits, 1);
    }

    tx.update(fixtureRef, {
      assignedTeacherId: teacherId,
      assignedTeacherName: teacherName,
      status: "assigned",
      assignedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(actionLabel === "auto_assigned" ? { autoAssigned: true } : {}),
    });

    committedFixture = fixture;
  });

  if (!committedFixture) return;

  const sourceSlotId = committedFixture.sourceDailySlotId;
  const date = committedFixture.date || "";
  if (sourceSlotId && date) {
    await h.db().collection("timetable_exceptions").doc(`${sourceSlotId}_${date}`).set(
      {
        slotId: sourceSlotId,
        date,
        type: "fixture_assigned",
        teacherId,
        teacherName,
        sourceId: fixtureId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }

  await h.db().collection("fixture_requests").add({
    fixtureId,
    teacherId,
    teacherName,
    action: actionLabel || "assigned_by_admin",
    status: "active",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const className = committedFixture.className || "a class";
  const day = committedFixture.day || "";
  const unit = committedFixture.unit;
  await notifyTeacher(
    teacherId,
    "Cover assigned",
    `An admin assigned you to cover ${className} (unit ${unit}) on ${day}.`,
    "fixtureAssigned",
    { fixtureId }
  );
}

exports.assignFixture = onCall(async (request) => {
  await requireAdmin(request);
  const { fixtureId, teacherId, teacherName } = request.data || {};
  if (!fixtureId || !teacherId) {
    throw new HttpsError("invalid-argument", "fixtureId and teacherId are required.");
  }
  await doAssignFixture(fixtureId, teacherId, teacherName || "Teacher", "assigned_by_admin");
  return { ok: true };
});

// ---------------------------------------------------------------------------
// exchangeFixture — a teacher who holds a claimed fixture hands it to
// another specific teacher. fromTeacherId is ALWAYS request.auth.uid (the
// person giving it away); toTeacherId is who the client says should receive
// it — that's legitimate (you're allowed to nominate who you're handing
// your own cover duty to), the function independently re-validates the
// recipient's eligibility (leave, quota) before committing either way.
// ---------------------------------------------------------------------------
exports.exchangeFixture = onCall(async (request) => {
  const fromTeacherId = requireAuth(request);
  const { fixtureId, toTeacherId } = request.data || {};
  if (!fixtureId || !toTeacherId) {
    throw new HttpsError("invalid-argument", "fixtureId and toTeacherId are required.");
  }
  if (toTeacherId === fromTeacherId) {
    throw new HttpsError("invalid-argument", "Cannot exchange a fixture with yourself.");
  }

  const fixtureRef = h.db().collection("fixtures").doc(fixtureId);
  const fixtureSnap = await fixtureRef.get();
  if (!fixtureSnap.exists) throw new HttpsError("not-found", "Fixture not found.");
  const fixture = fixtureSnap.data();

  const currentHolder = fixture.claimedBy || fixture.assignedTeacherId || "";
  if (currentHolder !== fromTeacherId) {
    throw new HttpsError("permission-denied", "Only the current teacher can exchange this fixture.");
  }

  const fixtureDate = fixture.date || "";
  if (fixtureDate) {
    const todayKey = h.dateKeyFor(new Date());
    if (fixtureDate === todayKey && (await h.isPastUnifiedCutoffNow())) {
      throw new HttpsError("failed-precondition", "Same-day fixture exchanges are blocked after cutoff time.");
    }
    // The recipient must not themselves be on approved leave that date —
    // otherwise the exchange would just create a brand-new uncovered gap.
    if (await h.isTeacherOnApprovedLeave(toTeacherId, fixtureDate)) {
      throw new HttpsError("failed-precondition", "The recipient is on approved leave on this date.");
    }
  }

  const recipientRef = h.db().collection("users").doc(toTeacherId);
  const recipientDoc = await recipientRef.get();
  if (!recipientDoc.exists) throw new HttpsError("not-found", "Recipient teacher not found.");
  const recipientName = recipientDoc.data().name || recipientDoc.data().email || "Teacher";
  const defaultUnits = await h.livePermanentUnits(toTeacherId);
  const maxUnits = await h.getMaxUnitsPerTeacher();

  const fromRef = h.db().collection("users").doc(fromTeacherId);

  await h.db().runTransaction(async (tx) => {
    const liveFixtureDoc = await tx.get(fixtureRef);
    const liveFixture = liveFixtureDoc.data();
    const liveHolder = liveFixture ? liveFixture.claimedBy || liveFixture.assignedTeacherId || "" : "";
    if (!liveFixtureDoc.exists || liveHolder !== fromTeacherId) {
      throw new HttpsError("failed-precondition", "This fixture is no longer yours to exchange.");
    }

    const recipientSnap = await tx.get(recipientRef);
    const liveFixtureUnits = (recipientSnap.data() && recipientSnap.data().fixtureUnits) || 0;
    if (defaultUnits + liveFixtureUnits >= maxUnits) {
      throw new HttpsError("failed-precondition", `${recipientName} is already at their ${maxUnits}-unit limit.`);
    }

    const fromSnap = await tx.get(fromRef);
    const fromUnits = (fromSnap.data() && fromSnap.data().fixtureUnits) || 0;

    tx.update(fixtureRef, {
      claimedBy: toTeacherId,
      claimedByName: recipientName,
      assignedTeacherId: null,
      assignedTeacherName: null,
      status: "claimed",
      exchangedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    h.applySafeFixtureUnitsAdjustment(tx, fromRef, fromUnits, -1);
    h.applySafeFixtureUnitsAdjustment(tx, recipientRef, liveFixtureUnits, 1);
  });

  const className = fixture.className || "a class";
  const day = fixture.day || "";
  const unit = fixture.unit;

  const sourceSlotId = fixture.sourceDailySlotId;
  const date = fixture.date || "";
  if (sourceSlotId && date) {
    await h.db().collection("timetable_exceptions").doc(`${sourceSlotId}_${date}`).set(
      {
        slotId: sourceSlotId,
        date,
        type: "fixture_assigned",
        teacherId: toTeacherId,
        teacherName: recipientName,
        sourceId: fixtureId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }

  await h.db().collection("fixture_requests").add({
    fixtureId,
    fromTeacherId,
    toTeacherId,
    toTeacherName: recipientName,
    action: "exchanged",
    status: "active",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await notifyTeacher(
    toTeacherId,
    "Cover handed to you",
    `You're now covering ${className} (unit ${unit}) on ${day}.`,
    "fixtureClaimed",
    { fixtureId }
  );
  await notifyTeacher(
    fromTeacherId,
    "Cover handed off",
    `${recipientName} is now covering ${className} (unit ${unit}) on ${day} instead of you.`,
    "fixtureClaimed",
    { fixtureId }
  );

  return { ok: true };
});

// ---------------------------------------------------------------------------
// expireFixturesSweep — callable by ANY signed-in user (same trigger pattern
// as before, from main_navigation_screen.dart), but runs with trusted
// privileges so decrementing an arbitrary OTHER teacher's fixtureUnits is
// safe and doesn't need that teacher's own session to be the one running it.
// ---------------------------------------------------------------------------
exports.expireFixturesSweep = onCall(async (request) => {
  requireAuth(request); // any signed-in user may trigger the sweep

  const now = new Date();
  const snap = await h.db().collection("fixtures").where("isExpired", "==", false).get();
  const toExpire = snap.docs.filter((doc) => {
    const data = doc.data();
    const expiresAt = data.expiresAt ? data.expiresAt.toDate() : null;
    return expiresAt && expiresAt < now && data.status !== "assigned";
  });

  if (toExpire.length === 0) return { expired: 0 };

  const batch = h.db().batch();
  for (const doc of toExpire) {
    const data = doc.data();
    batch.update(doc.ref, {
      isExpired: true,
      status: "expired",
      expiredAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (data.claimedBy) {
      // Best-effort plain increment here (not a read-then-clamp) — this
      // mirrors the existing batched-sweep tradeoff: `isExpired == false`
      // is a one-way gate so the same doc can never be expired twice, and
      // unlike the old client version this now always runs with trusted
      // privileges so a concurrent claim/release racing it is the only
      // remaining edge case, same as before.
      batch.update(h.db().collection("users").doc(data.claimedBy), {
        fixtureUnits: admin.firestore.FieldValue.increment(-1),
      });
    }
  }
  await batch.commit();

  return { expired: toExpire.length };
});

// ---------------------------------------------------------------------------
// triggerAutoAssign — the CLIENT still computes "who's the best recommended
// teacher" (read-only ranking, no privileged write — see
// FixtureService.getRecommendedTeachers, unchanged) and calls this with its
// pick; this function just re-validates and commits the actual assignment
// with trusted privileges, exactly like assignFixture, but allowed for any
// signed-in user (since the auto-assign sweep runs from any session) rather
// than admin-only.
// ---------------------------------------------------------------------------
exports.triggerAutoAssign = onCall(async (request) => {
  requireAuth(request);
  const { fixtureId, teacherId, teacherName } = request.data || {};
  if (!fixtureId || !teacherId) {
    throw new HttpsError("invalid-argument", "fixtureId and teacherId are required.");
  }
  await doAssignFixture(fixtureId, teacherId, teacherName || "Teacher", "auto_assigned");
  await notifyAdmins(
    "Auto-assigned cover",
    `${teacherName || "A teacher"} was automatically assigned — nobody claimed it in time.`,
    "fixture_auto_assigned",
    { fixtureId }
  );
  return { ok: true };
});

// ---------------------------------------------------------------------------
// resyncTeachers — pulls the full Firebase Auth user list (Admin SDK only;
// the client SDK can only ever see the currently signed-in user) and
// creates a `users/{uid}` doc for any account that authenticated but never
// got a Firestore profile written for it (closed the app before
// UserService.createUserIfNotExists ran, signed in directly against Auth
// outside the app flow, etc).
// ---------------------------------------------------------------------------
exports.resyncTeachers = onCall(async (request) => {
  await requireAdmin(request);

  let created = 0;
  let totalAuthUsers = 0;
  let nextPageToken;

  do {
    const listResult = await admin.auth().listUsers(1000, nextPageToken);
    nextPageToken = listResult.pageToken;
    totalAuthUsers += listResult.users.length;

    let batch = h.db().batch();
    let inBatch = 0;

    for (const u of listResult.users) {
      const ref = h.db().collection("users").doc(u.uid);
      const snap = await ref.get();
      if (snap.exists) continue;

      batch.set(ref, {
        uid: u.uid,
        name: u.displayName || "",
        email: u.email || "",
        role: "teacher",
        isAdmin: false,
        defaultUnits: 0,
        fixtureUnits: 0,
        photoUrl: u.photoURL || null,
        bio: "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        resyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      created++;
      inBatch++;

      // Firestore batches cap at 500 writes; chunk defensively.
      if (inBatch >= 450) {
        await batch.commit();
        batch = h.db().batch();
        inBatch = 0;
      }
    }

    if (inBatch > 0) {
      await batch.commit();
    }
  } while (nextPageToken);

  return { created, totalAuthUsers };
});

// ---------------------------------------------------------------------------
// deleteTeacher — admin-only. Removes the teacher's Firestore profile AND
// cleans up every place that referenced them (per-class `teachers[]` unit
// config, any weekly_timetables slot still assigned to them), so deleting a
// teacher doesn't leave ghost entries behind. Runs server-side (rather than
// as several separate client writes) so the cleanup is atomic-ish and can't
// be partially skipped by a client that only has rules-permitted access to
// some of these collections.
//
// NOTE: this does NOT delete the underlying Firebase Auth account. If the
// same person signs back in, createUserIfNotExists() will recreate a blank
// profile for them. Pass `alsoDeleteAuthAccount: true` to also remove their
// ability to sign in again.
// ---------------------------------------------------------------------------
exports.deleteTeacher = onCall(async (request) => {
  await requireAdmin(request);
  const { teacherId, alsoDeleteAuthAccount } = request.data || {};
  if (!teacherId) {
    throw new HttpsError("invalid-argument", "teacherId is required.");
  }

  // 1. Remove from every class's teachers[] array.
  const classesSnap = await h.db().collection("classes").get();
  for (const doc of classesSnap.docs) {
    const teachers = doc.data().teachers || [];
    if (teachers.some((t) => t.teacherId === teacherId)) {
      const updated = teachers.filter((t) => t.teacherId !== teacherId);
      await doc.ref.update({ teachers: updated });
    }
  }

  // 2. Clear any weekly_timetables slots still pointing at them.
  const slotsSnap = await h
    .db()
    .collection("weekly_timetables")
    .where("teacherId", "==", teacherId)
    .get();
  const slotsBatch = h.db().batch();
  for (const d of slotsSnap.docs) {
    slotsBatch.update(d.ref, { teacherId: "", teacherName: "" });
  }
  if (!slotsSnap.empty) {
    await slotsBatch.commit();
  }

  // 3. Delete the profile itself.
  await h.db().collection("users").doc(teacherId).delete();

  // 4. Optionally remove their ability to sign in again.
  let authAccountDeleted = false;
  if (alsoDeleteAuthAccount) {
    try {
      await admin.auth().deleteUser(teacherId);
      authAccountDeleted = true;
    } catch (e) {
      // Don't fail the whole call if the Auth account is already gone or
      // otherwise can't be removed — the Firestore cleanup above already
      // succeeded and is the more important part.
    }
  }

  return { ok: true, authAccountDeleted };
});

// ---------------------------------------------------------------------------
// clearTimetableSlot — admin-only. Removes the assigned teacher from a
// single weekly_timetables slot, leaving everything else about the slot
// (day/unit/startTime/endTime/classId) untouched. This is the server-side
// counterpart of the admin timetable grid's "Clear slot / remove teacher"
// popup menu option, scoped to exactly one slot — it does NOT touch any
// other slot for that teacher.
// ---------------------------------------------------------------------------
exports.clearTimetableSlot = onCall(async (request) => {
  await requireAdmin(request);
  const { slotId } = request.data || {};
  if (!slotId) {
    throw new HttpsError("invalid-argument", "slotId is required.");
  }

  const ref = h.db().collection("weekly_timetables").doc(slotId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Slot not found.");
  }
  const previousTeacherId = snap.data().teacherId || "";

  await ref.set(
    {
      teacherId: "",
      teacherName: "",
      originalTeacherId: "",
      type: "permanent",
      clearedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  if (previousTeacherId) {
    await notifyTeacher(
      previousTeacherId,
      "Timetable updated",
      "You were removed from a slot on your weekly timetable.",
      "classOccurring",
      { slotId }
    );
  }

  return { ok: true, previousTeacherId };
});

