# Authentification GitHub Actions au Vault partagé

Les ressources de `github-actions-oidc.yaml` permettent au workflow Terraform
de `ClubCedille/k8s-shared` de s'authentifier à Vault sans conserver de token
d'utilisateur.

Vault accepte uniquement les jetons OIDC GitHub qui correspondent à tous ces
attributs :

- dépôt : `ClubCedille/k8s-shared`
- identifiant du dépôt : `971715316`
- identifiant du propriétaire du dépôt : `6483038`
- branche : `refs/heads/main`
- workflow : `.github/workflows/apply-tf.yml` depuis `main`
- audience : `https://vault.etsmtl.club`

Le token Vault créé expire après 30 minutes et peut uniquement gérer les
chemins de secrets Node-RED et Outline utilisés par les modules Terraform.

## Déploiement

1. Fusionner et synchroniser ce dépôt en premier.
2. Vérifier les ressources dans le namespace `vault` :

   ```sh
   kubectl -n vault get \
     authenginemount/github-actions \
     jwtoidcauthengineconfig/github-actions-config \
     jwtoidcauthenginerole/k8s-shared-terraform \
     policy/k8s-shared-terraform
   ```

3. Fusionner ensuite le changement correspondant au workflow dans
   `ClubCedille/k8s-shared`.
4. Confirmer la réussite d'une exécution Terraform avant de supprimer le secret
   `VAULT_TOKEN` du dépôt.

