require "test_helper"

class StaticPagesTest < ActionDispatch::IntegrationTest
  test "principles page loads" do
    get principles_path
    assert_response :success
    assert_match "principles", response.body.downcase
  end

  test "architecture page loads" do
    get about_architecture_path
    assert_response :success
  end

  test "schema page loads" do
    get about_schema_path
    assert_response :success
  end

  test "appeal to scholars page loads" do
    get appeal_to_scholars_path
    assert_response :success
  end

  test "appeal to publishers page loads" do
    get appeal_to_publishers_path
    assert_response :success
  end
end
