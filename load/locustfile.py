from locust import HttpUser, task, between


class ShopApiUser(HttpUser):
    wait_time = between(0.1, 0.4)

    @task(8)
    def hot_work(self):
        self.client.get("/work?iters=120000", name="/work")

    @task(2)
    def index(self):
        self.client.get("/", name="/")

    @task(1)
    def error_path(self):
        self.client.get("/error", name="/error", catch_response=True)
