FROM ruby:3.3-alpine

RUN apk add --no-cache build-base sqlite-dev tzdata

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
ARG BUNDLE_WITHOUT=""
RUN bundle config set --local without "$BUNDLE_WITHOUT" && bundle install

COPY . .

RUN mkdir -p db

EXPOSE 4567

CMD ["bundle", "exec", "rackup", "config.ru", "-p", "4567", "-o", "0.0.0.0"]
