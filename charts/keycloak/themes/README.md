# DalaiLLAMA Keycloak Theme

Custom theme for DalaiLLAMA Contact Center matching the landing page design.

## Theme Features

- 🎨 Gray background (`bg-gray-300`) matching landing page
- 🦙 Llama logo in purple circle
- 🔵 Blue buttons (`bg-blue-600`) matching landing page
- 📱 Fully responsive
- 🔐 Custom login page
- 📝 Custom registration page
- 📧 Branded email templates

## Directory Structure

```
dalaillama/
├── theme.properties
├── login/
│   ├── theme.properties
│   ├── resources/css/dalaillama.css
│   └── messages/messages_en.properties
├── account/
│   └── theme.properties
└── email/
    ├── theme.properties
    └── messages/messages_en.properties
```

## Deployment (Docker Hub)

### 1. Build and Push to Docker Hub

```bash
cd keycloak-theme

# Login to Docker Hub
docker login

# Build the image
docker build -t dalaillama/keycloak-themes:latest .

# Push to Docker Hub
docker push dalaillama/keycloak-themes:latest
```

### 2. Update Helm values.yaml

```yaml
theme:
  enabled: true
  name: dalaillama
  useInitContainer: true
  initImage: dalaillama/keycloak-themes:latest
```

### 3. Update deployment.yaml init container

Add to your Keycloak deployment template:

```yaml
initContainers:
  - name: theme-init
    image: dalaillama/keycloak-themes:latest
    command: ['sh', '-c', 'cp -r /themes/* /opt/keycloak/themes/']
    volumeMounts:
      - name: themes
        mountPath: /opt/keycloak/themes
```

### 4. Deploy

```bash
helm upgrade keycloak ~/workspace/infra-platform/charts/keycloak -n auth
```

## Enable Registration in Keycloak

After deploying the theme, enable user registration:

1. Go to Keycloak Admin Console: `http://auth.localhost:8081/admin`
2. Select your realm (e.g., `dalaillama`)
3. Go to **Realm Settings** → **Login** tab
4. Enable **User registration**
5. Optionally enable:
   - Email as username
   - Forgot password
   - Remember me
   - Verify email
6. Go to **Realm Settings** → **Themes** tab
7. Set **Login theme** to `dalaillama`
8. Click **Save**

## Apply Theme to Realm

### Via Admin Console:
1. Go to **Realm Settings** → **Themes**
2. Select `dalaillama` for:
   - Login theme
   - Account theme
   - Email theme
3. Click **Save**

### Via Realm Import (in realm.json):
```json
{
  "realm": "dalaillama",
  "loginTheme": "dalaillama",
  "accountTheme": "dalaillama",
  "emailTheme": "dalaillama",
  "registrationAllowed": true,
  "registrationEmailAsUsername": true,
  "resetPasswordAllowed": true,
  "rememberMe": true,
  "verifyEmail": false
}
```

## Customization

### Change Colors

Edit `dalaillama/login/resources/css/dalaillama.css`:

```css
:root {
  --dl-primary: #7c3aed;        /* Main purple */
  --dl-primary-dark: #6d28d9;   /* Darker purple */
  --dl-secondary: #4f46e5;      /* Indigo */
  --dl-accent: #06b6d4;         /* Cyan accent */
}
```

### Add Logo

1. Add logo image to `dalaillama/login/resources/img/logo.png`
2. Update CSS:
   ```css
   .kc-logo-text::before {
     content: '';
     background: url('../img/logo.png') no-repeat center;
     background-size: contain;
     width: 60px;
     height: 60px;
     display: block;
     margin: 0 auto 16px;
   }
   ```

### Change Text

Edit `dalaillama/login/messages/messages_en.properties`:

```properties
loginTitle=Welcome to Your App
loginSubtitle=Your custom subtitle here
```

## Testing

1. Go to login page: `http://auth.localhost:8081/realms/dalaillama/account`
2. Click "Register" to test registration
3. Test forgot password flow

## Troubleshooting

### Theme not showing
```bash
# Check if theme is mounted
kubectl exec -n auth deploy/keycloak -c keycloak -- ls -la /opt/keycloak/themes/

# Restart Keycloak to reload themes
kubectl rollout restart deployment/keycloak -n auth
```

### CSS not loading
- Check browser dev tools for 404 errors
- Verify file paths in theme.properties
- Clear browser cache

### Registration not working
- Ensure registration is enabled in realm settings
- Check Keycloak logs for errors
