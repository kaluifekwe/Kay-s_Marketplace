import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import { Typography, Tag, Descriptions } from "antd";
import { naira, statusColor } from "../../format";

const { Title } = Typography;

export const OrderShow = () => {
  const { queryResult } = useShow();
  const record = queryResult?.data?.data;

  return (
    <Show isLoading={queryResult?.isLoading} title="Order">
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Order ID">{record?.id ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Status">
          <Tag color={statusColor(record?.status)}>{record?.status ?? "—"}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="Buyer ID">
          {record?.buyer_id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Vendor ID">
          {record?.vendor_id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Items subtotal">
          {naira(record?.total)}
        </Descriptions.Item>
        <Descriptions.Item label="Total (with delivery)">
          {naira(record?.total_with_delivery ?? record?.total)}
        </Descriptions.Item>
        <Descriptions.Item label="Escrow">
          {record?.payment_released ? (
            <Tag color="green">Released to vendor</Tag>
          ) : (
            <Tag color="blue">Held</Tag>
          )}
        </Descriptions.Item>
        <Descriptions.Item label="Has dispute">
          {record?.has_dispute ? <Tag color="red">Yes</Tag> : "No"}
        </Descriptions.Item>
        <Descriptions.Item label="Placed">
          {record?.created_at ?? "—"}
        </Descriptions.Item>
      </Descriptions>
      <Title level={5} style={{ marginTop: 24, color: "#888" }}>
        Line items, delivery tracking and admin actions (force-release, refund,
        cancel) land here in Phase 2.
      </Title>
    </Show>
  );
};
