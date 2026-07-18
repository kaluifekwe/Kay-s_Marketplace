import { useCallback, useEffect, useState } from "react";
import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import {
  Typography,
  Tag,
  Descriptions,
  Card,
  Statistic,
  Button,
  Modal,
  Form,
  InputNumber,
  Input,
  Radio,
  Table,
  Space,
  App,
} from "antd";
import { WalletOutlined, PlusOutlined, MinusOutlined } from "@ant-design/icons";
import { naira } from "../../format";
import { supabaseClient } from "../../supabaseClient";

const { Title, Text } = Typography;

interface WalletRow {
  balance: number;
  status: string;
  currency: string;
}
interface LedgerRow {
  id: string;
  amount: number;
  balance_after: number;
  type: string;
  description?: string;
  created_at: string;
}

export const UserShow = () => {
  const { message } = App.useApp();
  const { queryResult } = useShow();
  const record = queryResult?.data?.data as Record<string, any> | undefined;
  const userId = record?.id as string | undefined;

  const [wallet, setWallet] = useState<WalletRow | null>(null);
  const [ledger, setLedger] = useState<LedgerRow[]>([]);
  const [loadingWallet, setLoadingWallet] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [form] = Form.useForm();
  const direction = Form.useWatch("direction", form);

  const loadWallet = useCallback(async () => {
    if (!userId) return;
    setLoadingWallet(true);
    const [{ data: w }, { data: tx }] = await Promise.all([
      supabaseClient.from("wallets").select("balance,status,currency").eq("user_id", userId).maybeSingle(),
      supabaseClient
        .from("wallet_transactions")
        .select("id,amount,balance_after,type,description,created_at")
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .limit(10),
    ]);
    setWallet((w as WalletRow) ?? null);
    setLedger((tx as LedgerRow[]) ?? []);
    setLoadingWallet(false);
  }, [userId]);

  useEffect(() => {
    loadWallet();
  }, [loadWallet]);

  const submitAdjust = async () => {
    const values = await form.validateFields();
    setSubmitting(true);
    try {
      const { data, error } = await supabaseClient.functions.invoke("admin-wallet-adjust", {
        body: {
          user_id: userId,
          amount: values.amount,
          direction: values.direction,
          reason: values.reason,
        },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).message || (data as any).error);
      message.success(
        `${values.direction === "credit" ? "Credited" : "Debited"} ${naira(values.amount)} — new balance ${naira(
          (data as any).balance,
        )}.`,
      );
      setModalOpen(false);
      form.resetFields();
      loadWallet();
    } catch (e: any) {
      message.error(String(e?.context?.error || e?.message || "Adjustment failed."));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Show isLoading={queryResult?.isLoading} title={record?.name ?? "User"}>
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Name">{record?.name ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Email">{record?.email ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Phone">{record?.phone ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Role">
          <Tag>{record?.role ?? "—"}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="State">{record?.state ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="KYC (NIN/BVN)">
          {record?.nin ? "Verified" : "Not verified"}
        </Descriptions.Item>
        <Descriptions.Item label="Kays Credit">{record?.kays_credit ?? 0}</Descriptions.Item>
        <Descriptions.Item label="Payout blocked">
          {record?.payout_blocked ? <Tag color="red">Yes</Tag> : <Tag color="green">No</Tag>}
        </Descriptions.Item>
        <Descriptions.Item label="User ID">{record?.id ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Store ID">{record?.store_id ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Joined">{record?.created_at ?? "—"}</Descriptions.Item>
      </Descriptions>

      <Card
        style={{ marginTop: 24, borderTop: "3px solid #1b8a3a" }}
        title={
          <Space>
            <WalletOutlined /> Wallet
          </Space>
        }
        extra={
          <Button type="primary" onClick={() => setModalOpen(true)} disabled={!userId}>
            Adjust balance
          </Button>
        }
        loading={loadingWallet}
      >
        <Statistic
          title={`Balance${wallet?.status && wallet.status !== "active" ? ` (${wallet.status})` : ""}`}
          value={naira(wallet?.balance ?? 0)}
        />
        <Title level={5} style={{ marginTop: 24 }}>
          Recent wallet activity
        </Title>
        <Table
          dataSource={ledger}
          rowKey="id"
          size="small"
          pagination={false}
          locale={{ emptyText: "No wallet transactions yet." }}
        >
          <Table.Column
            dataIndex="created_at"
            title="When"
            render={(v: string) => new Date(v).toLocaleString()}
          />
          <Table.Column dataIndex="type" title="Type" render={(v: string) => <Tag>{v}</Tag>} />
          <Table.Column
            dataIndex="amount"
            title="Amount"
            align="right"
            render={(v: number) => (
              <Text type={v < 0 ? "danger" : "success"}>
                {v < 0 ? "-" : "+"}
                {naira(Math.abs(v))}
              </Text>
            )}
          />
          <Table.Column
            dataIndex="balance_after"
            title="Balance after"
            align="right"
            render={(v: number) => naira(v)}
          />
          <Table.Column dataIndex="description" title="Description" render={(v: string) => v ?? "—"} />
        </Table>
      </Card>

      <Modal
        title="Adjust wallet balance"
        open={modalOpen}
        onOk={submitAdjust}
        onCancel={() => setModalOpen(false)}
        okText="Apply adjustment"
        confirmLoading={submitting}
        okButtonProps={{ danger: direction === "debit" }}
      >
        <Form form={form} layout="vertical" initialValues={{ direction: "credit" }}>
          <Form.Item name="direction" label="Direction" rules={[{ required: true }]}>
            <Radio.Group optionType="button" buttonStyle="solid">
              <Radio.Button value="credit">
                <PlusOutlined /> Credit (add)
              </Radio.Button>
              <Radio.Button value="debit">
                <MinusOutlined /> Debit (remove)
              </Radio.Button>
            </Radio.Group>
          </Form.Item>
          <Form.Item
            name="amount"
            label="Amount (₦)"
            rules={[
              { required: true, message: "Enter an amount" },
              { type: "number", min: 1, message: "Amount must be positive" },
            ]}
          >
            <InputNumber
              style={{ width: "100%" }}
              min={1}
              step={100}
              precision={2}
              placeholder="e.g. 500"
            />
          </Form.Item>
          <Form.Item
            name="reason"
            label="Reason (recorded in the ledger for audit)"
            rules={[{ required: true, message: "A reason is required" }]}
          >
            <Input.TextArea rows={2} placeholder="e.g. Goodwill credit for delayed delivery (ticket #123)" />
          </Form.Item>
          <Text type="secondary">
            This moves real money in the user's wallet and is recorded against your admin account.
          </Text>
        </Form>
      </Modal>
    </Show>
  );
};
