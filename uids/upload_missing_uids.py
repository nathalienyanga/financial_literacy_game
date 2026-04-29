import firebase_admin
from firebase_admin import credentials, firestore

# The 17 missing UIDs
MISSING = [
    {"uid": "UGCG217", "firstName": "BARBRA",   "lastName": "NASSAKA",               "usageLog": []},
    {"uid": "UGCG218", "firstName": "CHARLES",  "lastName": "KADDU LUBEGA",           "usageLog": []},
    {"uid": "UGCG219", "firstName": "SEPIRIA",  "lastName": "SSEBUGWAWO",             "usageLog": []},
    {"uid": "UGCG220", "firstName": "CHARLES",  "lastName": "WALUKAGGA",              "usageLog": []},
    {"uid": "UGCG221", "firstName": "AZIZA",    "lastName": "NAKYANZI",               "usageLog": []},
    {"uid": "UGCG222", "firstName": "KEZIA",    "lastName": "NANSUBUGA",              "usageLog": []},
    {"uid": "UGCG223", "firstName": "INNOCENT", "lastName": "MAGEZI",                 "usageLog": []},
    {"uid": "UGCG224", "firstName": "HERMAN",   "lastName": "MATOVU",                 "usageLog": []},
    {"uid": "UGCG225", "firstName": "EDWARD",   "lastName": "WALULYA KAMULEGEYA",     "usageLog": []},
    {"uid": "UGCG226", "firstName": "GEORGE",   "lastName": "KALIMBA",                "usageLog": []},
    {"uid": "UGCG227", "firstName": "RICHARD",  "lastName": "KIMULI",                 "usageLog": []},
    {"uid": "UGCG228", "firstName": "JOSEPH",   "lastName": "SSEMANDA",               "usageLog": []},
    {"uid": "UGEX219", "firstName": "SHAMIRA",  "lastName": "NAMUKOBE",               "usageLog": []},
    {"uid": "UGEX220", "firstName": "MARIAM",   "lastName": "KWAGALA",                "usageLog": []},
    {"uid": "UGEX221", "firstName": "SANIYA",   "lastName": "NAKITANDWE",             "usageLog": []},
    {"uid": "UGEX222", "firstName": "PROSSY",   "lastName": "NABULUMBA",              "usageLog": []},
    {"uid": "UGEX225", "firstName": "HADIJA",   "lastName": "KAFUKO",                 "usageLog": []},
]

REGION_MAP = {"C": "Central", "E": "Eastern"}

def region_for(uid):
    return REGION_MAP.get(uid[2].upper())

def upload_to(db, project_name):
    by_region = {}
    for entry in MISSING:
        r = region_for(entry["uid"])
        by_region.setdefault(r, []).append(entry)

    print(f"\n--- Uploading to {project_name} ---")
    for region, entries in by_region.items():
        doc_ref = db.collection("uidLists").document(region)
        existing = doc_ref.get()
        if existing.exists:
            existing_uids = {e["uid"] for e in existing.to_dict().get("uids", [])}
            to_add = [e for e in entries if e["uid"] not in existing_uids]
            already = [e["uid"] for e in entries if e["uid"] in existing_uids]
            if to_add:
                doc_ref.update({"uids": firestore.ArrayUnion(to_add)})
                print(f"  {region}: added {[e['uid'] for e in to_add]}")
            if already:
                print(f"  {region}: already present {already}")
        else:
            doc_ref.set({"uids": entries, "enumerators": []})
            print(f"  {region}: created doc with {[e['uid'] for e in entries]}")

# --- App 1: finlitsim (service account) ---
cred1 = credentials.Certificate("firebase_admin.json")
app1 = firebase_admin.initialize_app(cred1, name="finlitsim")
db1 = firestore.client(app=app1)
upload_to(db1, "finlitsim")

# --- App 2: ofinsen-dc06d (application default credentials) ---
cred2 = credentials.ApplicationDefault()
app2 = firebase_admin.initialize_app(cred2, {"projectId": "ofinsen-dc06d"}, name="ofinsen")
db2 = firestore.client(app=app2)
upload_to(db2, "ofinsen-dc06d")

print("\nDone.")