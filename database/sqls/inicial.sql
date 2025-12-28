create database tenants;

-- ==========================
-- SaaS Multi-tenant (tenant_id por coluna) - PostgreSQL
-- ==========================

-- Extensões úteis
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ==========================
-- ENUMS (opcional, mas ajuda)
-- ==========================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE user_role AS ENUM ('ORG_ADMIN', 'MEMBER', 'SUPER_ADMIN');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invite_status') THEN
    CREATE TYPE invite_status AS ENUM ('PENDING', 'ACCEPTED', 'CANCELLED', 'EXPIRED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_status') THEN
    CREATE TYPE subscription_status AS ENUM ('TRIAL', 'ACTIVE', 'PAST_DUE', 'CANCELLED', 'SUSPENDED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invoice_status') THEN
    CREATE TYPE invoice_status AS ENUM ('PENDING', 'PAID', 'OVERDUE', 'CANCELLED', 'REFUNDED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN
    CREATE TYPE payment_status AS ENUM ('AUTHORIZED', 'CONFIRMED', 'FAILED', 'REFUNDED', 'CHARGEBACK');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_status') THEN
    CREATE TYPE task_status AS ENUM ('TODO', 'DOING', 'DONE', 'CANCELLED');
  END IF;
END$$;

-- ==========================
-- TABELA: organizations (tenants)
-- ==========================
CREATE TABLE IF NOT EXISTS organizations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              VARCHAR(150) NOT NULL,
  slug              VARCHAR(150) NOT NULL UNIQUE,
  status            SMALLINT NOT NULL DEFAULT 1, -- 1=active, 0=blocked (simples)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ==========================
-- TABELA: users (usuários)
-- ==========================
CREATE TABLE IF NOT EXISTS users (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  role              user_role NOT NULL DEFAULT 'MEMBER',
  name              VARCHAR(150) NOT NULL,
  email             VARCHAR(180) NOT NULL,
  password_hash     TEXT NOT NULL,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- email global único (muito comum)
  CONSTRAINT uq_users_email UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS ix_users_tenant ON users(tenant_id);
CREATE INDEX IF NOT EXISTS ix_users_role ON users(role);

-- ==========================
-- TABELA: organization_invites (convites)
-- ==========================
CREATE TABLE IF NOT EXISTS organization_invites (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email             VARCHAR(180) NOT NULL,
  invited_role      user_role NOT NULL DEFAULT 'MEMBER',
  token_hash        TEXT NOT NULL,
  status            invite_status NOT NULL DEFAULT 'PENDING',
  expires_at        TIMESTAMPTZ NOT NULL,
  accepted_at       TIMESTAMPTZ NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_invite_per_tenant_email UNIQUE (tenant_id, email)
);

CREATE INDEX IF NOT EXISTS ix_invites_tenant_status ON organization_invites(tenant_id, status);

-- ==========================
-- TABELA: plans (planos)
-- ==========================
CREATE TABLE IF NOT EXISTS plans (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              VARCHAR(120) NOT NULL UNIQUE,
  description       TEXT NULL,
  price_cents       INTEGER NOT NULL DEFAULT 0,
  currency          CHAR(3) NOT NULL DEFAULT 'BRL',
  period_months     INTEGER NOT NULL DEFAULT 1, -- 1=mensal, 12=anual etc.
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,

  -- limites por plano (exemplos)
  max_users         INTEGER NULL,
  max_projects      INTEGER NULL,
  max_tasks         INTEGER NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_plans_price_nonneg CHECK (price_cents >= 0),
  CONSTRAINT ck_plans_period_positive CHECK (period_months > 0)
);

-- ==========================
-- TABELA: subscriptions (assinaturas do tenant)
-- ==========================
CREATE TABLE IF NOT EXISTS subscriptions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  plan_id           UUID NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,

  status            subscription_status NOT NULL DEFAULT 'TRIAL',

  started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  current_period_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  current_period_end   TIMESTAMPTZ NOT NULL,
  cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
  canceled_at       TIMESTAMPTZ NULL,

  trial_ends_at     TIMESTAMPTZ NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- um tenant tem no máximo uma assinatura ativa "principal"
  CONSTRAINT uq_subscriptions_tenant UNIQUE (tenant_id)
);

CREATE INDEX IF NOT EXISTS ix_subscriptions_status ON subscriptions(status);

-- ==========================
-- TABELA: invoices (faturas)
-- ==========================
CREATE TABLE IF NOT EXISTS invoices (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  subscription_id   UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,

  status            invoice_status NOT NULL DEFAULT 'PENDING',
  invoice_number    VARCHAR(50) NOT NULL,
  amount_cents      INTEGER NOT NULL,
  currency          CHAR(3) NOT NULL DEFAULT 'BRL',

  due_date          DATE NOT NULL,
  paid_at           TIMESTAMPTZ NULL,

  period_start      TIMESTAMPTZ NOT NULL,
  period_end        TIMESTAMPTZ NOT NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_invoice_number UNIQUE (invoice_number),
  CONSTRAINT ck_invoice_amount_nonneg CHECK (amount_cents >= 0),
  CONSTRAINT ck_invoice_period CHECK (period_end > period_start)
);

CREATE INDEX IF NOT EXISTS ix_invoices_tenant_status ON invoices(tenant_id, status);
CREATE INDEX IF NOT EXISTS ix_invoices_due_date ON invoices(due_date);

-- ==========================
-- TABELA: payments (pagamentos)
-- ==========================
CREATE TABLE IF NOT EXISTS payments (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  invoice_id        UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,

  status            payment_status NOT NULL DEFAULT 'AUTHORIZED',
  provider          VARCHAR(80) NOT NULL DEFAULT 'manual', -- ex: stripe, pagseguro, manual
  provider_ref      VARCHAR(120) NULL,

  amount_cents      INTEGER NOT NULL,
  currency          CHAR(3) NOT NULL DEFAULT 'BRL',

  paid_at           TIMESTAMPTZ NULL,
  metadata          JSONB NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_payment_amount_nonneg CHECK (amount_cents >= 0)
);

CREATE INDEX IF NOT EXISTS ix_payments_tenant_status ON payments(tenant_id, status);
CREATE INDEX IF NOT EXISTS ix_payments_invoice ON payments(invoice_id);

-- ==========================
-- CORE: projects
-- ==========================
CREATE TABLE IF NOT EXISTS projects (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  name              VARCHAR(180) NOT NULL,
  description       TEXT NULL,
  is_archived       BOOLEAN NOT NULL DEFAULT FALSE,

  created_by_user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_project_name_per_tenant UNIQUE (tenant_id, name)
);

CREATE INDEX IF NOT EXISTS ix_projects_tenant_archived ON projects(tenant_id, is_archived);

-- ==========================
-- CORE: tasks
-- ==========================
CREATE TABLE IF NOT EXISTS tasks (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  title             VARCHAR(200) NOT NULL,
  description       TEXT NULL,

  status            task_status NOT NULL DEFAULT 'TODO',
  due_at            TIMESTAMPTZ NULL,

  assigned_user_id  UUID NULL REFERENCES users(id) ON DELETE SET NULL,
  created_by_user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_tasks_tenant_project ON tasks(tenant_id, project_id);
CREATE INDEX IF NOT EXISTS ix_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS ix_tasks_assigned ON tasks(assigned_user_id);

-- ==========================
-- EVENT OUTBOX (para integração com Notification Hub)
-- Padrão Outbox: você grava eventos aqui e um worker envia pro Notification Hub
-- ==========================
CREATE TABLE IF NOT EXISTS outbox_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NULL REFERENCES organizations(id) ON DELETE CASCADE,

  event_type        VARCHAR(120) NOT NULL, -- ex: SubscriptionPaid
  payload           JSONB NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  processed_at      TIMESTAMPTZ NULL,
  status            VARCHAR(30) NOT NULL DEFAULT 'PENDING', -- PENDING, PROCESSED, FAILED
  attempts          INTEGER NOT NULL DEFAULT 0,
  last_error        TEXT NULL
);

CREATE INDEX IF NOT EXISTS ix_outbox_status ON outbox_events(status);
CREATE INDEX IF NOT EXISTS ix_outbox_tenant ON outbox_events(tenant_id);

-- ==========================
-- AUDIT LOG (opcional)
-- ==========================
CREATE TABLE IF NOT EXISTS audit_logs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id           UUID NULL REFERENCES users(id) ON DELETE SET NULL,

  action            VARCHAR(120) NOT NULL, -- ex: "subscription.upgrade"
  entity_type       VARCHAR(120) NULL,     -- ex: "Subscription"
  entity_id         UUID NULL,
  metadata          JSONB NULL,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_audit_tenant_created ON audit_logs(tenant_id, created_at);

-- ==========================
-- TRIGGERS simples para updated_at
-- ==========================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  -- organizations
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tg_organizations_updated_at') THEN
    CREATE TRIGGER tg_organizations_updated_at
    BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  -- users
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tg_users_updated_at') THEN
    CREATE TRIGGER tg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  -- plans
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tg_plans_updated_at') THEN
    CREATE TRIGGER tg_plans_updated_at
    BEFORE UPDATE ON plans
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  -- subscriptions
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tg_subscriptions_updated_at') THEN
    CREATE TRIGGER tg_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  -- projects
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tg_projects_updated_at') THEN
    CREATE TRIGGER tg_projects_updated_at
    BEFORE UPDATE ON projects
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  -- tasks
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tg_tasks_updated_at') THEN
    CREATE TRIGGER tg_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

-- ==========================
-- DADOS INICIAIS (opcional)
-- ==========================
-- Planos exemplo
INSERT INTO plans (name, description, price_cents, currency, period_months, max_users, max_projects, max_tasks)
VALUES
('Free', 'Plano gratuito para validação', 0, 'BRL', 1, 3, 3, 200),
('Pro', 'Plano profissional para pequenas equipes', 4990, 'BRL', 1, 15, 50, 5000),
('Enterprise', 'Plano avançado para empresas', 19990, 'BRL', 1, NULL, NULL, NULL)
ON CONFLICT (name) DO NOTHING;
