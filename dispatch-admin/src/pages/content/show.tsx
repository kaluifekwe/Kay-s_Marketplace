import { useEffect, useState } from "react";
import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import {
  Typography,
  Tag,
  Descriptions,
  Card,
  Input,
  Button,
  Space,
  Popconfirm,
  Alert,
  Tabs,
  App,
} from "antd";
import {
  CheckCircleOutlined,
  CloseCircleOutlined,
  ThunderboltOutlined,
  SaveOutlined,
} from "@ant-design/icons";
import { supabaseClient } from "../../supabaseClient";
import { fnError } from "../../fnError";

const { Text, Paragraph } = Typography;

type Draft = {
  article_title: string;
  slug: string;
  meta_description: string;
  article_content: string;
  hero_image_url: string;
  social_facebook: string;
  social_instagram: string;
  social_x: string;
  social_linkedin: string;
  social_whatsapp_status: string;
};

const EMPTY_DRAFT: Draft = {
  article_title: "",
  slug: "",
  meta_description: "",
  article_content: "",
  hero_image_url: "",
  social_facebook: "",
  social_instagram: "",
  social_x: "",
  social_linkedin: "",
  social_whatsapp_status: "",
};

const HAS_DRAFT_STATUSES = ["DRAFTED", "REVIEW", "APPROVED", "PUBLISHED", "UPDATED"];

export const ContentShow = () => {
  const { message } = App.useApp();
  const { queryResult } = useShow({ resource: "content_items" });
  const record = queryResult?.data?.data as Record<string, any> | undefined;

  const [draft, setDraft] = useState<Draft>(EMPTY_DRAFT);
  const [generating, setGenerating] = useState(false);
  const [saving, setSaving] = useState(false);
  const [deciding, setDeciding] = useState<"approve" | "reject" | null>(null);

  // Load the record's current values into the editable form once it arrives.
  // Re-syncs whenever a fresh record comes in (e.g. right after Generate).
  useEffect(() => {
    if (!record) return;
    setDraft({
      article_title: record.article_title ?? "",
      slug: record.slug ?? "",
      meta_description: record.meta_description ?? "",
      article_content: record.article_content ?? "",
      hero_image_url: record.hero_image_url ?? "",
      social_facebook: record.social_facebook ?? "",
      social_instagram: record.social_instagram ?? "",
      social_x: record.social_x ?? "",
      social_linkedin: record.social_linkedin ?? "",
      social_whatsapp_status: record.social_whatsapp_status ?? "",
    });
  }, [record?.id, record?.updated_at]);

  const set = (field: keyof Draft) => (e: any) =>
    setDraft((d) => ({ ...d, [field]: e.target.value }));

  const status = record?.content_status as string | undefined;
  const hasDraft = !!status && HAS_DRAFT_STATUSES.includes(status);
  const isPublished = status === "PUBLISHED" || status === "UPDATED";

  const generate = async () => {
    if (!record) return;
    setGenerating(true);
    try {
      const { data, error } = await supabaseClient.functions.invoke("generate-blog-draft", {
        body: { content_id: record.id },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      message.success(`Draft generated (via ${(data as any)?.model ?? "AI"}). Review it below.`);
      queryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Could not generate a draft."));
    } finally {
      setGenerating(false);
    }
  };

  const saveDraft = async () => {
    if (!record) return;
    setSaving(true);
    try {
      const { error } = await supabaseClient
        .from("content_items")
        .update({ ...draft, updated_at: new Date().toISOString() })
        .eq("id", record.id);
      if (error) throw error;
      message.success("Saved.");
      queryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Could not save your edits."));
    } finally {
      setSaving(false);
    }
  };

  const decide = async (decision: "approve" | "reject") => {
    if (!record) return;
    setDeciding(decision);
    try {
      const {
        data: { user },
      } = await supabaseClient.auth.getUser();
      const patch =
        decision === "approve"
          ? {
              content_status: "PUBLISHED",
              published_at: new Date().toISOString(),
              approved_by: user?.id,
              updated_at: new Date().toISOString(),
            }
          : { content_status: "REJECTED", updated_at: new Date().toISOString() };
      const { error } = await supabaseClient.from("content_items").update(patch).eq("id", record.id);
      if (error) throw error;
      message.success(decision === "approve" ? "Published to the live site." : "Rejected.");
      queryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Could not complete that."));
    } finally {
      setDeciding(null);
    }
  };

  const busyAny = generating || saving || deciding !== null;

  return (
    <Show isLoading={queryResult?.isLoading} title="Content item" headerButtons={() => null}>
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Topic">{record?.topic ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Keyword">{record?.keyword ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Audience">
          <Tag color={record?.audience === "vendor" ? "purple" : "blue"}>{record?.audience}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="Category / State">
          {record?.category ?? "—"} {record?.state ? `· ${record.state}` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Search intent">{record?.search_intent ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Research summary">{record?.research_summary ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Source">
          {record?.source ?? "—"}
          {record?.source_url ? (
            <>
              {" · "}
              <a href={record.source_url} target="_blank" rel="noreferrer">
                link
              </a>
            </>
          ) : null}
        </Descriptions.Item>
        <Descriptions.Item label="Status">
          <Tag>{status ?? "—"}</Tag>
        </Descriptions.Item>
      </Descriptions>

      {isPublished ? (
        <Alert
          style={{ marginTop: 24 }}
          type="success"
          showIcon
          message="Published"
          description={
            record?.slug ? (
              <>
                Live at <Text code>/blog/{record.slug}</Text>. Edits below save immediately but don't
                need re-approval.
              </>
            ) : (
              "This post is live."
            )
          }
        />
      ) : null}

      <Card style={{ marginTop: 24, borderTop: "3px solid #1b8a3a" }} title="Draft">
        {!hasDraft ? (
          <Paragraph type="secondary">No draft yet. Generate one from the research above.</Paragraph>
        ) : null}

        <Space style={{ marginBottom: 16 }}>
          <Button
            icon={<ThunderboltOutlined />}
            loading={generating}
            disabled={busyAny && !generating}
            onClick={generate}
          >
            {hasDraft ? "Regenerate draft" : "Generate draft"}
          </Button>
          <Button icon={<SaveOutlined />} loading={saving} disabled={busyAny && !saving} onClick={saveDraft}>
            Save edits
          </Button>
        </Space>

        {hasDraft ? (
          <Tabs
            items={[
              {
                key: "article",
                label: "Blog article",
                children: (
                  <Space direction="vertical" style={{ width: "100%" }} size={12}>
                    <div>
                      <Text strong>Title</Text>
                      <Input value={draft.article_title} onChange={set("article_title")} />
                    </div>
                    <div>
                      <Text strong>Slug</Text>
                      <Input value={draft.slug} onChange={set("slug")} addonBefore="/blog/" />
                    </div>
                    <div>
                      <Text strong>Meta description</Text>
                      <Input.TextArea rows={2} value={draft.meta_description} onChange={set("meta_description")} />
                    </div>
                    <div>
                      <Text strong>Hero image URL</Text>
                      <Input
                        value={draft.hero_image_url}
                        onChange={set("hero_image_url")}
                        placeholder="Auto-picked from Unsplash on generate, or paste your own"
                      />
                      {record?.hero_image_credit ? (
                        <Text type="secondary" style={{ fontSize: 12 }}>
                          Photo by {record.hero_image_credit} on Unsplash — attribution shown automatically on
                          the blog. Pasting a different URL here clears that credit on next generate.
                        </Text>
                      ) : null}
                    </div>
                    <div>
                      <Text strong>Article body (Markdown)</Text>
                      <Input.TextArea rows={20} value={draft.article_content} onChange={set("article_content")} />
                    </div>
                  </Space>
                ),
              },
              {
                key: "social",
                label: "Social posts (copy-paste)",
                children: (
                  <Space direction="vertical" style={{ width: "100%" }} size={12}>
                    <div>
                      <Text strong>Facebook</Text>
                      <Input.TextArea rows={4} value={draft.social_facebook} onChange={set("social_facebook")} />
                    </div>
                    <div>
                      <Text strong>Instagram caption</Text>
                      <Input.TextArea rows={4} value={draft.social_instagram} onChange={set("social_instagram")} />
                    </div>
                    <div>
                      <Text strong>X (Twitter)</Text>
                      <Input.TextArea rows={3} value={draft.social_x} onChange={set("social_x")} />
                    </div>
                    <div>
                      <Text strong>LinkedIn</Text>
                      <Input.TextArea rows={4} value={draft.social_linkedin} onChange={set("social_linkedin")} />
                    </div>
                    <div>
                      <Text strong>WhatsApp status</Text>
                      <Input.TextArea rows={2} value={draft.social_whatsapp_status} onChange={set("social_whatsapp_status")} />
                    </div>
                  </Space>
                ),
              },
            ]}
          />
        ) : null}
      </Card>

      {hasDraft && !isPublished ? (
        <Card style={{ marginTop: 24 }} title="Decision">
          <Paragraph type="secondary" style={{ marginTop: 0 }}>
            <b>Publish</b> makes this live on the public blog immediately (save your edits first —
            publishing uses whatever is currently saved, not what's unsaved in the boxes above).{" "}
            <b>Reject</b> keeps it out of the queue's default view; you can still reopen and regenerate
            it later.
          </Paragraph>
          <Space>
            <Popconfirm
              title="Publish this post?"
              description="It goes live on the public site immediately."
              okText="Publish"
              onConfirm={() => decide("approve")}
            >
              <Button
                type="primary"
                icon={<CheckCircleOutlined />}
                loading={deciding === "approve"}
                disabled={busyAny && deciding !== "approve"}
              >
                Publish
              </Button>
            </Popconfirm>
            <Popconfirm
              title="Reject this draft?"
              okText="Reject"
              okButtonProps={{ danger: true }}
              onConfirm={() => decide("reject")}
            >
              <Button
                danger
                icon={<CloseCircleOutlined />}
                loading={deciding === "reject"}
                disabled={busyAny && deciding !== "reject"}
              >
                Reject
              </Button>
            </Popconfirm>
          </Space>
        </Card>
      ) : null}
    </Show>
  );
};
