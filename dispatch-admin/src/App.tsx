import { Authenticated, Refine } from "@refinedev/core";
import {
  ThemedLayoutV2,
  ErrorComponent,
  useNotificationProvider,
  AuthPage,
  ThemedTitleV2,
} from "@refinedev/antd";
import "@refinedev/antd/dist/reset.css";
import { dataProvider, liveProvider } from "@refinedev/supabase";
import routerBindings, {
  CatchAllNavigate,
  NavigateToResource,
  DocumentTitleHandler,
  UnsavedChangesNotifier,
} from "@refinedev/react-router-v6";
import { App as AntdApp, ConfigProvider } from "antd";
import { BrowserRouter, Outlet, Route, Routes } from "react-router-dom";
import {
  ShoppingOutlined,
  TeamOutlined,
  WarningOutlined,
} from "@ant-design/icons";

import { supabaseClient } from "./supabaseClient";
import { authProvider } from "./authProvider";
import { UserList, UserShow } from "./pages/users";
import { OrderList, OrderShow } from "./pages/orders";
import { DisputeList, DisputeShow } from "./pages/disputes";

const BRAND = "#1b8a3a"; // Kays Market green

function App() {
  return (
    <BrowserRouter>
      <ConfigProvider theme={{ token: { colorPrimary: BRAND } }}>
        <AntdApp>
          <Refine
            dataProvider={dataProvider(supabaseClient)}
            liveProvider={liveProvider(supabaseClient)}
            authProvider={authProvider}
            routerProvider={routerBindings}
            notificationProvider={useNotificationProvider}
            resources={[
              {
                name: "orders",
                list: "/orders",
                show: "/orders/show/:id",
                meta: { label: "Orders", icon: <ShoppingOutlined /> },
              },
              {
                name: "disputes",
                list: "/disputes",
                show: "/disputes/show/:id",
                meta: { label: "Disputes", icon: <WarningOutlined /> },
              },
              {
                name: "users",
                list: "/users",
                show: "/users/show/:id",
                meta: { label: "Users", icon: <TeamOutlined /> },
              },
            ]}
            options={{
              syncWithLocation: true,
              warnWhenUnsavedChanges: true,
            }}
          >
            <Routes>
              <Route
                element={
                  <Authenticated
                    key="authenticated-routes"
                    fallback={<CatchAllNavigate to="/login" />}
                  >
                    <ThemedLayoutV2
                      Title={({ collapsed }) => (
                        <ThemedTitleV2
                          collapsed={collapsed}
                          text="Kays Market"
                          icon={<ShoppingOutlined />}
                        />
                      )}
                    >
                      <Outlet />
                    </ThemedLayoutV2>
                  </Authenticated>
                }
              >
                <Route index element={<NavigateToResource resource="orders" />} />
                <Route path="/orders">
                  <Route index element={<OrderList />} />
                  <Route path="show/:id" element={<OrderShow />} />
                </Route>
                <Route path="/disputes">
                  <Route index element={<DisputeList />} />
                  <Route path="show/:id" element={<DisputeShow />} />
                </Route>
                <Route path="/users">
                  <Route index element={<UserList />} />
                  <Route path="show/:id" element={<UserShow />} />
                </Route>
                <Route path="*" element={<ErrorComponent />} />
              </Route>

              <Route
                element={
                  <Authenticated key="auth-pages" fallback={<Outlet />}>
                    <NavigateToResource resource="orders" />
                  </Authenticated>
                }
              >
                <Route
                  path="/login"
                  element={
                    <AuthPage
                      type="login"
                      registerLink={false}
                      forgotPasswordLink={false}
                      title={
                        <ThemedTitleV2
                          collapsed={false}
                          text="Kays Market Admin"
                          icon={<ShoppingOutlined />}
                        />
                      }
                    />
                  }
                />
              </Route>
            </Routes>

            <UnsavedChangesNotifier />
            <DocumentTitleHandler />
          </Refine>
        </AntdApp>
      </ConfigProvider>
    </BrowserRouter>
  );
}

export default App;
