const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

admin.initializeApp();

// ---------------------------------------------------------------------------
// REVERSAL NOTE (see also firestore.rules "fixtureUnitsStepOnly"):
//
// claimFixture, releaseFixture, assignFixture, exchangeFixture,
// expireFixturesSweep, triggerAutoAssign, deleteTeacher, and
// clearTimetableSlot were all moved BACK to the client
// (lib/core/services/fixture_service.dart and admin_service.dart), by
// deliberate decision, accepting weaker write-validation guarantees than
// trusted server code could offer for the cross-user writes those flows
// involve. See firestore.rules for the corresponding rule loosening.
//
// `resyncTeachers` below is the ONE function that could NOT move to the
// client, for a structural reason rather than a preference: it calls
// `admin.auth().listUsers()`, which enumerates every Firebase Auth
// account in the project. The Firebase client SDK has no equivalent —
// by design, a client can only ever see the currently signed-in user,
// never the full account list. There is no client-side substitute for
// this; it must stay a privileged server-side call.
// ---------------------------------------------------------------------------

async function requireAdmin(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  const doc = await admin.firestore().collection("admins").doc(request.auth.uid).get();
  if (!doc.exists) {
    throw new HttpsError("permission-denied", "Admin only.");
  }
  return request.auth.uid;
}

exports.resyncTeachers = onCall(async (request) => {
  await requireAdmin(request);

  let created = 0;
  let totalAuthUsers = 0;
  let nextPageToken;

  do {
    const listResult = await admin.auth().listUsers(1000, nextPageToken);
    nextPageToken = listResult.pageToken;
    totalAuthUsers += listResult.users.length;

    let batch = admin.firestore().batch();
    let inBatch = 0;

    for (const u of listResult.users) {
      const ref = admin.firestore().collection("users").doc(u.uid);
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
        batch = admin.firestore().batch();
        inBatch = 0;
      }
    }

    if (inBatch > 0) {
      await batch.commit();
    }
  } while (nextPageToken);

  return { created, totalAuthUsers };
});
