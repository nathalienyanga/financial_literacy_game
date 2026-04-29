import csv
import firebase_admin
from firebase_admin import credentials, firestore, initialize_app

cred = credentials.Certificate('firebase_admin.json')
app = initialize_app(cred)
db = firestore.client()

REGION_MAP = {
    'N': 'Northern',
    'E': 'Eastern',
    'W': 'Western',
    'C': 'Central',
}

def region_for_uid(uid):
    # UID format: UG<N|E|W|C><G|X>nnn
    if len(uid) >= 3:
        return REGION_MAP.get(uid[2].upper())
    return None

# --- Read CSV ---
seen_uids = set()
uids_by_region = {}

with open("uids_phase1.csv", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    next(reader)  # skip header
    for row in reader:
        row = [c.strip() for c in row]
        if not row or not row[0]:
            continue
        uid = row[0].strip().upper()
        if not uid:
            continue
        first_name = row[1].strip() if len(row) > 1 else ""
        last_name  = row[2].strip() if len(row) > 2 else ""

        if uid in seen_uids:
            print(f"  [skip dup] {uid}")
            continue
        seen_uids.add(uid)

        region = region_for_uid(uid)
        if not region:
            print(f"  [skip unknown region] {uid}")
            continue

        uids_by_region.setdefault(region, []).append({
            "uid": uid,
            "firstName": first_name,
            "lastName": last_name,
            "usageLog": [],
        })

print(f"\nLoaded {len(seen_uids)} unique UIDs across {len(uids_by_region)} regions\n")

# --- Merge into Firestore ---
uidLists = db.collection("uidLists")

for region, new_entries in uids_by_region.items():
    doc_ref = uidLists.document(region)
    existing = doc_ref.get()

    if existing.exists:
        existing_uids = {e["uid"] for e in existing.to_dict().get("uids", [])}
        to_add = [e for e in new_entries if e["uid"] not in existing_uids]
        if to_add:
            doc_ref.update({"uids": firestore.ArrayUnion(to_add)})
            print(f"  {region}: added {len(to_add)} new UIDs  (skipped {len(new_entries)-len(to_add)} already present)")
        else:
            print(f"  {region}: all {len(new_entries)} UIDs already present — no changes")
    else:
        doc_ref.set({"uids": new_entries, "enumerators": []})
        print(f"  {region}: created new doc with {len(new_entries)} UIDs")

print("\nDone.")