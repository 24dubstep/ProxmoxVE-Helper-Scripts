"""
Master License Generator Script (For Owner Hardware / Master Server)
Generates the encrypted licensing vault file to automatically unlock Super Admin Master Machine status.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from core.license_manager import LicenseManager
from core.licensing_vault import LicensingVault, VAULT_FILE

def main():
    print("[+] Initializing License Manager...")
    mgr = LicenseManager()

    if not mgr.is_master_machine():
        print("[+] Creating Master Vault...")
        payload = {
            "is_master": True,
            "signature": "SUPER_ADMIN_VALIDATED",
            "owner": "Mcanon / Master Server",
            "secret_salt": "MASTER_SERVER_EXCLUSIVE_SECRET_999",
            "issued_for": "Owner Machine"
        }
        enc_str = LicensingVault.encrypt_vault(payload)
        with open(VAULT_FILE, "w", encoding="utf-8") as f:
            f.write(enc_str)

    if mgr.is_master_machine():
        print(f"[SUCCESS] Master Vault File verified at: {VAULT_FILE}")
        print("[+] Tier: SUPER_ADMIN (Full privileges & Client License Generator unlocked)")
    else:
        print("[!] Error: Master license generation failed.")

if __name__ == "__main__":
    main()

