"""
Build Encrypted Licensing Vault Script
Compiles master secrets and Super Admin status into .master_vault.enc for your master server.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from core.licensing_vault import LicensingVault, VAULT_FILE

def main():
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

    print(f"[SUCCESS] Encrypted Licensing Vault created at: {VAULT_FILE}")
    print("[+] Master Vault unlocked:", LicensingVault.is_vault_unlocked())

if __name__ == "__main__":
    main()
