"""PyInstaller runtime hook: use bundled roots for HTTPS on a clean Mac."""
import os
import certifi

# CPython's build-machine OpenSSL paths need not exist on the receiving Mac.
# Preserve an explicit user CA override; the default travels with the helper.
os.environ.setdefault("SSL_CERT_FILE", certifi.where())
