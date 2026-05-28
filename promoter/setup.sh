#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
CONFIG_FILE="${SCRIPT_DIR}/config.local.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found."
  echo "Copy config.env to config.local.env and fill in your values:"
  echo "  cp ${SCRIPT_DIR}/config.env ${CONFIG_FILE}"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate required config
for var in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_FILE; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in $CONFIG_FILE"
    exit 1
  fi
done

if [[ ! -f "${GITHUB_APP_PRIVATE_KEY_FILE}" ]]; then
  echo "ERROR: GitHub App private key file not found: ${GITHUB_APP_PRIVATE_KEY_FILE}"
  exit 1
fi

PROMOTER_IMAGE="${PROMOTER_IMAGE:-quay.io/argoprojlabs/gitops-promoter}"
PROMOTER_TAG="${PROMOTER_TAG:-v0.27.1}"
PROMOTER_INSTALL_URL="${PROMOTER_INSTALL_URL:-}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-promoter-demo}"

echo "=== gcp-hcp-gitops-promoter-demo setup ==="
echo "  Minikube profile:  $MINIKUBE_PROFILE"
echo "  Promoter image:    $PROMOTER_IMAGE:$PROMOTER_TAG"
echo "  Install URL:       ${PROMOTER_INSTALL_URL:-<custom image>}"
echo ""

# --- Step 1: Minikube ---
echo "--- Step 1: Starting minikube ---"
if minikube status -p "$MINIKUBE_PROFILE" &>/dev/null; then
  echo "Minikube profile '$MINIKUBE_PROFILE' already running."
else
  minikube start -p "$MINIKUBE_PROFILE" --memory=4096 --cpus=2
fi
kubectl config use-context "$MINIKUBE_PROFILE"

# --- Step 2: Install gitops-promoter ---
echo "--- Step 2: Installing gitops-promoter ---"
if [[ -n "$PROMOTER_INSTALL_URL" ]]; then
  echo "Installing from release manifest: $PROMOTER_INSTALL_URL"
  curl -sL "$PROMOTER_INSTALL_URL" > "${SCRIPT_DIR}/install.yaml"
  kubectl apply -k "${SCRIPT_DIR}"

  MANIFEST_DEFAULT_TAG=$(grep -oP 'image: \K.*gitops-promoter:\S+' "${SCRIPT_DIR}/install.yaml" | head -1 || true)
  DESIRED="${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  if [[ -n "$MANIFEST_DEFAULT_TAG" && "$MANIFEST_DEFAULT_TAG" != "$DESIRED" ]]; then
    echo "Overriding image to $DESIRED"
    kubectl -n promoter-system set image deployment/promoter-controller-manager \
      manager="${DESIRED}"
  fi
else
  echo "No install URL set. Using custom image..."
  if ! minikube -p "$MINIKUBE_PROFILE" image ls | grep -q "${PROMOTER_IMAGE}:${PROMOTER_TAG}"; then
    echo "Loading ${PROMOTER_IMAGE}:${PROMOTER_TAG} into minikube..."
    minikube -p "$MINIKUBE_PROFILE" image load "${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  fi

  if [[ -f "${SCRIPT_DIR}/install.yaml" ]]; then
    echo "Applying from setup/install.yaml..."
    kubectl apply -k "${SCRIPT_DIR}" 2>/dev/null || true
    sleep 3
    kubectl apply -k "${SCRIPT_DIR}"
    kubectl -n promoter-system set image deployment/promoter-controller-manager \
      manager="${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  else
    echo "ERROR: No install.yaml found. Run ./build-from-pr.sh first, or set PROMOTER_INSTALL_URL."
    exit 1
  fi
fi

# Install ArgoCD CRDs (the promoter controller watches Application resources)
echo "Installing ArgoCD CRDs..."
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/application-crd.yaml 2>/dev/null
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/appproject-crd.yaml 2>/dev/null

echo "Waiting for promoter controller to be ready..."
kubectl -n promoter-system rollout status deployment/promoter-controller-manager --timeout=120s

# --- Step 3: Create GitHub App secret and ScmProvider ---
echo "--- Step 3: Configuring ScmProvider ---"
kubectl create namespace promoter-system 2>/dev/null || true

kubectl create secret generic github-app-key \
  --namespace=promoter-system \
  --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply ScmProvider with correct App IDs
sed \
  -e "s/appID: 0/appID: ${GITHUB_APP_ID}/" \
  -e "s/installationID: 0/installationID: ${GITHUB_APP_INSTALLATION_ID}/" \
  "${SCRIPT_DIR}/scm-provider.yaml" | kubectl apply -f -

kubectl apply -f "${SCRIPT_DIR}/git-repository.yaml"

# --- Step 4: Apply PromotionStrategy and commit status resources ---
echo "--- Step 4: Applying PromotionStrategy and commit status gates ---"
kubectl apply -f "${SCRIPT_DIR}/promotion-strategy.yaml"
kubectl apply -f "${SCRIPT_DIR}/commit-status/"

# --- Step 5: Create environment branches ---
echo "--- Step 5: Creating environment branches (if missing) ---"
cd "$REPO_DIR"
BRANCHES=(
  "environment/integration/main"
  "environment/stage/main"
  "environment/production/prod-1"
  "environment/production/prod-2"
  "environment/production/prod-3"
)
for branch in "${BRANCHES[@]}"; do
  if git ls-remote --exit-code origin "$branch" &>/dev/null; then
    echo "  Branch $branch already exists."
  else
    echo "  Creating $branch..."
    git checkout --orphan "$branch"
    git rm -rf . 2>/dev/null || true
    git -c commit.gpgsign=false commit --allow-empty -m "initialize $branch"
    git push origin "$branch"
    git checkout main
  fi
done

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Verify the controller is running:"
echo "     kubectl -n promoter-system get pods"
echo ""
echo "  2. Check PromotionStrategy status:"
echo "     kubectl -n promoter-system get promotionstrategy"
echo ""
echo "  3. Push a change to main to trigger hydration:"
echo "     # edit any file under argocd/config/ or terraform/, commit, push"
echo ""
echo "  4. Monitor promotion:"
echo "     watch -n5 promoter/status.sh"
echo ""
echo "  5. (Optional) Open the dashboard:"
echo "     kubectl -n promoter-system port-forward svc/promoter-dashboard 8080:8080"
