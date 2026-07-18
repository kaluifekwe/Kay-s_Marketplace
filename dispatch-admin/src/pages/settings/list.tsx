import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Card,
  Typography,
  InputNumber,
  Switch,
  Input,
  Button,
  Space,
  Alert,
  Spin,
  Tag,
  App,
} from "antd";
import { SaveOutlined } from "@ant-design/icons";
import { supabaseClient } from "../../supabaseClient";

const { Title, Text, Paragraph } = Typography;

interface Setting {
  key: string;
  value: unknown;
  value_type: "number" | "boolean" | "string";
  category: string;
  description?: string;
  min_value?: number | null;
  max_value?: number | null;
  updated_at?: string;
}

const CATEGORY_LABELS: Record<string, string> = {
  delivery: "Delivery",
  wallet: "Wallet & payouts",
  disputes: "Disputes",
  features: "Features",
  general: "General",
};

export const SettingsList = () => {
  const { message } = App.useApp();
  const [settings, setSettings] = useState<Setting[]>([]);
  const [draft, setDraft] = useState<Record<string, unknown>>({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabaseClient
      .from("app_settings")
      .select("key,value,value_type,category,description,min_value,max_value,updated_at")
      .order("category")
      .order("key");
    if (error) setError(error.message);
    else {
      setSettings((data as Setting[]) ?? []);
      setDraft(Object.fromEntries(((data as Setting[]) ?? []).map((s) => [s.key, s.value])));
      setError(null);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const save = async (s: Setting) => {
    setSaving(s.key);
    try {
      const { data, error } = await supabaseClient.functions.invoke("admin-update-setting", {
        body: { key: s.key, value: draft[s.key] },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      message.success(`Saved "${s.key}". Live within a minute.`);
      load();
    } catch (e: any) {
      message.error(String(e?.context?.error || e?.message || "Could not save."));
    } finally {
      setSaving(null);
    }
  };

  const grouped = useMemo(() => {
    const g: Record<string, Setting[]> = {};
    for (const s of settings) (g[s.category] ??= []).push(s);
    return g;
  }, [settings]);

  if (loading) {
    return (
      <div style={{ textAlign: "center", padding: 80 }}>
        <Spin size="large" />
      </div>
    );
  }

  if (error) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load settings"
        description={`${error}. Have you run app_settings.sql?`}
      />
    );
  }

  const editor = (s: Setting) => {
    const v = draft[s.key];
    if (s.value_type === "boolean") {
      return (
        <Switch
          checked={v === true || v === "true"}
          onChange={(checked) => setDraft((d) => ({ ...d, [s.key]: checked }))}
        />
      );
    }
    if (s.value_type === "number") {
      return (
        <InputNumber
          value={Number(v)}
          min={s.min_value ?? undefined}
          max={s.max_value ?? undefined}
          onChange={(n) => setDraft((d) => ({ ...d, [s.key]: n }))}
          style={{ width: 160 }}
        />
      );
    }
    return (
      <Input
        value={String(v ?? "")}
        onChange={(e) => setDraft((d) => ({ ...d, [s.key]: e.target.value }))}
        style={{ maxWidth: 320 }}
      />
    );
  };

  return (
    <>
      <Title level={3} style={{ marginTop: 0 }}>
        Settings
      </Title>
      <Paragraph type="secondary">
        Business configuration the apps read live — no deploy needed. A change takes effect within
        about a minute. Secrets (payment keys, webhook secrets) are deliberately not here; they stay
        in the server environment.
      </Paragraph>

      {Object.entries(grouped).map(([category, rows]) => (
        <Card
          key={category}
          title={CATEGORY_LABELS[category] ?? category}
          style={{ marginBottom: 20, borderTop: "3px solid #1b8a3a" }}
        >
          {rows.map((s, i) => {
            const changed = JSON.stringify(draft[s.key]) !== JSON.stringify(s.value);
            return (
              <div
                key={s.key}
                style={{
                  display: "flex",
                  gap: 16,
                  alignItems: "flex-start",
                  padding: "12px 0",
                  borderTop: i === 0 ? undefined : "1px solid #f0f0f0",
                }}
              >
                <div style={{ flex: 1, minWidth: 0 }}>
                  <Text strong style={{ fontFamily: "monospace" }}>
                    {s.key}
                  </Text>
                  {changed && (
                    <Tag color="orange" style={{ marginLeft: 8 }}>
                      unsaved
                    </Tag>
                  )}
                  <div>
                    <Text type="secondary" style={{ fontSize: 13 }}>
                      {s.description ?? "—"}
                    </Text>
                  </div>
                </div>
                <Space>
                  {editor(s)}
                  <Button
                    type="primary"
                    icon={<SaveOutlined />}
                    size="small"
                    disabled={!changed || saving !== null}
                    loading={saving === s.key}
                    onClick={() => save(s)}
                  >
                    Save
                  </Button>
                </Space>
              </div>
            );
          })}
        </Card>
      ))}
    </>
  );
};
