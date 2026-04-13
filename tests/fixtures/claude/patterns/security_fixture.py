# Fixture for check-security patterns.sh
# Contains known-detectable patterns for each category

# hardcoded-secret: AWS access key pattern
AWS_KEY = "AKIAIOSFODNN7EXAMPLE"

# injection-risk: SQL in f-string
def get_user(user_id):
    query = f"SELECT * FROM users WHERE id = {user_id}"
    return query

# insecure-crypto: weak hash
import hashlib
def hash_password(pw):
    return md5(pw)
